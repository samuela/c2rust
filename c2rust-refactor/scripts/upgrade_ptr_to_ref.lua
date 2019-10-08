require "pl"

-- Take a set of node ids (locals/params/fields) and turn them (if a pointer)
-- into a reference or Box
Variable = {}

function Variable.new(node_id, kind)
    self = {}
    self.id = node_id
    self.kind = kind
    self.shadowed = false

    setmetatable(self, Variable)
    Variable.__index = Variable

    return self
end

Field = {}

function Field.new(node_id)
    self = {}
    self.id = node_id

    setmetatable(self, Field)
    Field.__index = Field

    return self
end

function strip_int_suffix(expr)
    if expr:get_kind() == "Lit" then
        local lit = expr:get_node()

        if lit then
            lit:strip_suffix()
            expr:to_lit(lit)
        end
    end

    return expr
end

Struct = {}

function Struct.new(lifetimes, is_copy)
    self = {}
    self.lifetimes = lifetimes
    self.is_copy = is_copy

    setmetatable(self, Struct)
    Struct.__index = Struct

    return self
end

Fn = {}

function Fn.new(node_id, is_foreign, arg_ids)
    self = {}
    self.id = node_id
    self.is_foreign = is_foreign
    self.arg_ids = arg_ids

    setmetatable(self, Fn)
    Fn.__index = Fn

    return self
end

ConvCfg = {}

function ConvCfg.new(args)
    self = {}
    self.conv_type = args[1]

    for i, arg in ipairs(args) do
        args[i] = args[i + 1]
    end

    self.extra_data = args

    setmetatable(self, ConvCfg)
    ConvCfg.__index = ConvCfg

    return self
end

function ConvCfg:is_mut()
    if self.extra_data.mutability == nil then
        return nil
    end

    return self.extra_data.mutability == "mut"
end

function ConvCfg.from_marks(marks, attrs)
    local opt = true
    local slice = false
    local mutability = nil
    local binding = nil
    local conv_type = ""
    local mut = marks["mut"]
    local ref = marks["ref"]
    local move = marks["move"]
    local box = marks["box"]

    for _, attr in ipairs(attrs) do
        local attr_ident = attr:ident()

        if attr_ident == "nonnull" then
            opt = false
        elseif attr_ident == "slice" then
            slice = true
        end
    end

    -- TODO: And technically move is mutually exclusive too
    if ref and mut then
        log_error("Found both ref and mut marks on a single type")
        return
    end

    if opt then
        conv_type = "opt_"
    end

    -- Box and Move are not identical, but have overlap
    if box or move then
        conv_type = conv_type .. "box"

        if slice then
            conv_type = conv_type .. "_slice"
        end
    elseif ref then
        mutability = "immut"

        if slice then
            conv_type = conv_type .. "slice"
        else
            conv_type = conv_type .. "ref"
        end
    elseif mut then
        mutability = "mut"
        binding = "ByValMut"

        if slice then
            conv_type = conv_type .. "slice"
        else
            conv_type = conv_type .. "ref"
        end
    end

    if conv_type == "" or stringx.endswith(conv_type, "_") then
        log_error("Could not build appropriate conversion cfg from: " .. pretty.write(marks))
        return
    end

    return ConvCfg.new{conv_type, mutability=mutability, binding=binding}
end

function ConvCfg:is_slice()
    return self.conv_type == "slice"
end

function ConvCfg:is_ref()
    return self.conv_type == "ref"
end

function ConvCfg:is_ref_any()
    return self:is_ref() or self:is_opt_ref()
end

function ConvCfg:is_ref_or_slice()
    return self:is_ref() or self:is_slice()
end

function ConvCfg:is_opt_ref()
    return self.conv_type == "opt_ref"
end

function ConvCfg:is_opt_slice()
    return self.conv_type == "opt_slice"
end

function ConvCfg:is_opt_any()
    return self:is_opt_box_any() or self:is_opt_ref() or self:is_opt_slice()
end

function ConvCfg:is_opt_box()
    return self.conv_type == "opt_box"
end

function ConvCfg:is_opt_box_slice()
    return self.conv_type == "opt_box_slice"
end

function ConvCfg:is_opt_box_any()
    return self:is_opt_box() or self:is_opt_box_slice()
end

function ConvCfg:is_slice_any()
    return self:is_slice() or self:is_opt_box_slice() or self:is_box_slice() or self:is_opt_slice()
end

function ConvCfg:is_box_slice()
    return self.conv_type == "box_slice"
end

function ConvCfg:is_box()
    return self.conv_type == "box"
end

function ConvCfg:is_box_any()
    return self:is_opt_box_any() or self:is_box_slice() or self:is_box()
end

function ConvCfg:is_del()
    return self.conv_type == "del"
end

function ConvCfg:is_byteswap()
    return self.conv_type == "byteswap"
end

function ConvCfg:is_array()
    return self.conv_type == "array"
end

Visitor = {}

function Visitor.new(tctx, node_id_cfgs)
    self = {}
    self.tctx = tctx
    -- NodeId -> ConvCfg
    self.node_id_cfgs = node_id_cfgs
    -- PatHrId [except statics] -> Variable
    self.vars = {}
    -- HrId -> Field
    self.fields = {}
    -- HrId -> Struct
    self.structs = {}
    -- HrId -> Fn
    self.fns = {}

    setmetatable(self, Visitor)
    Visitor.__index = Visitor

    return self
end

function Visitor:get_param_cfg(fn, idx)
    if not fn then return end

    local arg_id = fn.arg_ids[idx]

    return self.node_id_cfgs[arg_id]
end

-- Takes a ptr type and returns the newly modified type
function upgrade_ptr(ptr_ty, conversion_cfg)
    local mut_ty = ptr_ty:get_mut_ty()
    local pointee_ty = mut_ty:get_ty()

    -- If we explicitly specify mutability, enforce its application
    -- otherwise we leave it as was (ie *const -> &, *mut -> &mut)
    if conversion_cfg.extra_data.mutability == "mut" then
        mut_ty:set_mutable(true)
    elseif conversion_cfg.extra_data.mutability == "immut" then
        mut_ty:set_mutable(false)
    end

    -- T -> [T]
    if conversion_cfg:is_slice_any() then
        pointee_ty:wrap_in_slice()
    end

    local non_boxed_slice = conversion_cfg:is_slice_any() and not conversion_cfg:is_box_any()

    -- T -> &T / &mut T or [T] -> &[T] / &mut [T]
    if conversion_cfg:is_ref_any() or non_boxed_slice then
        mut_ty:set_ty(pointee_ty)
        pointee_ty:to_rptr(conversion_cfg.extra_data.lifetime, mut_ty)

        if not conversion_cfg:is_box_any() and not conversion_cfg:is_opt_any() then
            return pointee_ty
        end
    end

    -- T -> Box<T> or [T] -> Box<[T]>
    if conversion_cfg:is_box_any() then
        pointee_ty:wrap_as_generic_angle_arg("Box")
    end

    -- Box<T> -> Option<Box<T>> or Box<[T]> -> Option<Box<[T]>>
    if conversion_cfg:is_opt_any() then
        pointee_ty:wrap_as_generic_angle_arg("Option")
    end

    return pointee_ty
end

function Visitor:flat_map_param(arg)
    local arg_id = arg:get_id()
    local conversion_cfg = self.node_id_cfgs[arg_id]

    if conversion_cfg then
        local arg_ty = arg:get_ty()

        if conversion_cfg.extra_data.binding then
            arg:set_binding(conversion_cfg.extra_data.binding)
        end

        if arg_ty:get_kind() == "Ptr" then
            local arg_pat_hrid = self.tctx:nodeid_to_hirid(arg:get_pat_id())

            self:add_var(arg_pat_hrid, Variable.new(arg_id, "param"))

            arg:set_ty(upgrade_ptr(arg_ty, conversion_cfg))
        end
    end

    return {arg}
end

function Visitor:add_var(hirid, var)
    if hirid then
        local hirid_str = tostring(hirid)

        self.vars[hirid_str] = var
    end
end

function Visitor:get_var(hirid)
    local hirid_str = tostring(hirid)

    return self.vars[hirid_str]
end

function Visitor:add_fn(hirid, fn)
    if hirid then
        local hirid_str = tostring(hirid)

        self.fns[hirid_str] = fn
    end
end

function Visitor:get_fn(hirid)
    local hirid_str = tostring(hirid)

    return self.fns[hirid_str]
end

function Visitor:add_field(hirid, field)
    if hirid then
        local hirid_str = tostring(hirid)

        self.fields[hirid_str] = field
    end
end

function Visitor:get_field(hirid)
    local hirid_str = tostring(hirid)

    return self.fields[hirid_str]
end

function Visitor:add_struct(hirid, struct)
    if hirid then
        local hirid_str = tostring(hirid)

        self.structs[hirid_str] = struct
    end
end

function Visitor:get_struct(hirid)
    local hirid_str = tostring(hirid)

    return self.structs[hirid_str]
end

function Visitor:visit_expr(expr)
    local expr_kind = expr:get_kind()

    if expr_kind == "Field" then
        self:rewrite_field_expr(expr)
    elseif expr_kind == "Unary" and expr:get_op() == "Deref" then
        self:rewrite_deref_expr(expr)
    elseif expr_kind == "Assign" then
        self:rewrite_assign_expr(expr)
    elseif expr_kind == "Call" then
        self:rewrite_call_expr(expr)
    elseif expr_kind == "MethodCall" then
        self:rewrite_method_call_expr(expr)
    end
end

function Visitor:rewrite_method_call_expr(expr)
    local exprs = expr:get_exprs()
    local method_name = expr:get_method_name()

    -- x.offset(y) -> &x[y..] or Some(&x.unwrap()[y..])
    -- Only really works for positive pointer offsets
    if method_name == "offset" then
        local offset_expr, caller = self:rewrite_chained_offsets(expr)
        local cfg = self:get_expr_cfg(caller)

        if not cfg or not cfg:is_slice_any() then return end

        offset_expr:to_range(offset_expr, nil)

        local is_mut = cfg:is_mut()

        if cfg:is_opt_any() then
            if is_mut then
                caller:to_method_call("as_mut", {caller})
            end

            caller:to_method_call("unwrap", {caller})
        end

        expr:to_index(caller, offset_expr)
        expr:to_addr_of(expr, is_mut)
    -- static_var.as_mut/ptr -> &[mut]static_var
    elseif method_name == "as_ptr" or method_name == "as_mut_ptr" then
        local hirid = self.tctx:resolve_path_hirid(exprs[1])
        local var = hirid and self:get_var(hirid)

        if var and var.kind == "static" then
            expr:to_addr_of(exprs[1], method_name == "as_mut_ptr")
        end
    -- p.is_null() -> p.is_none() or false when not using an option
    elseif method_name == "is_null" then
        local callee = expr:get_exprs()[1]
        local conversion_cfg = self:get_expr_cfg(callee)

        if not conversion_cfg then
            return
        end

        if conversion_cfg:is_opt_any() then
            expr:set_method_name("is_none")
        else
            expr:to_bool_lit(false)
        end
    elseif method_name == "wrapping_offset_from" then
        local lhs_cfg = self:get_expr_cfg(exprs[1])
        local rhs_cfg = self:get_expr_cfg(exprs[2])

        if lhs_cfg then
            exprs[1] = decay_ref_to_ptr(exprs[1], lhs_cfg)
        end

        if rhs_cfg then
            exprs[2] = decay_ref_to_ptr(exprs[2], rhs_cfg)
        end

        expr:to_method_call("wrapping_offset_from", {exprs[1], exprs[2]})
    end
end

-- Extracts a raw pointer from a rewritten rust type
function decay_ref_to_ptr(expr, cfg, for_struct_field)
    if cfg:is_opt_any() then
        if cfg:is_mut() then
            expr:to_method_call("as_mut", {expr})
        end

        expr:to_method_call("unwrap", {expr})
    end

    if cfg:is_slice_any() then
        if cfg:is_mut() then
            expr:to_method_call("as_mut_ptr", {expr})
        else
            expr:to_method_call("as_ptr", {expr})
        end
    -- If we're using the expr in a field ie (*e.as_mut().unwrap()).bar then
    -- we can skip the deref as rust will do it automatically
    elseif cfg:is_mut() and cfg:is_opt_any() and not for_struct_field then
        expr:to_unary("Deref", expr)
    elseif cfg.extra_data.non_null_wrapped then
        expr:to_method_call("as_ptr", {expr})
    end

    return expr
end

function Visitor:rewrite_field_expr(expr)
    local field_expr = expr:get_exprs()[1]

    if field_expr:get_kind() == "Unary" and field_expr:get_op() == "Deref" then
        local derefed_expr = field_expr:get_exprs()[1]

        if derefed_expr:get_kind() == "Path" then
            local cfg = self:get_expr_cfg(derefed_expr)

            -- This is a path we're expecting to modify
            if not cfg then
                return
            end

            -- (*foo).bar -> (foo.as_mut().unwrap()).bar
            if cfg:is_opt_any() then
                derefed_expr = decay_ref_to_ptr(derefed_expr, cfg, true)
            end

            -- (*foo).bar -> (foo).bar (can't remove parens..)
            expr:set_exprs{derefed_expr}
        end
    end
end

function Visitor:rewrite_chained_offsets(unwrapped_expr)
    local offset_expr = nil

    while true do
        local unwrapped_exprs = unwrapped_expr:get_exprs()
        unwrapped_expr = unwrapped_exprs[1]
        local method_name = unwrapped_expr:get_method_name()

        -- Accumulate offset params
        if not offset_expr then
            offset_expr = strip_int_suffix(unwrapped_exprs[2])
        else
            offset_expr:to_binary("Add", strip_int_suffix(unwrapped_exprs[2]), offset_expr)
        end

        -- May start with conversion to pointer if an array
        if method_name == "as_mut_ptr" then
            local unwrapped_exprs = unwrapped_expr:get_exprs()
            unwrapped_expr = unwrapped_exprs[1]

            break
        elseif method_name ~= "offset" then
            break
        end
    end

    return offset_expr, unwrapped_expr
end

function Visitor:rewrite_deref_expr(expr)
    local derefed_exprs = expr:get_exprs()
    local unwrapped_expr = derefed_exprs[1]

    -- *p.offset(x).offset(y) -> p[x + y] (pointer) or
    -- *p.as_mut_ptr().offset(x).offset(y) -> p[x + y] (array)
    if unwrapped_expr:get_method_name() == "offset" then
        local offset_expr, unwrapped_expr = self:rewrite_chained_offsets(unwrapped_expr)

        -- Should be left with a path or field, otherwise bail
        local cfg = self:get_expr_cfg(unwrapped_expr)

        if not cfg then
            return
        end

        -- We only want to apply this operation if we're converting
        -- a pointer to an array/slice
        if cfg:is_slice_any() or cfg:is_array() then
            -- If we're using an option, we must unwrap (or map/match) using
            -- as_mut (or as_ref) to avoid a move:
            -- *ptr[1] -> *ptr.as_mut().unwrap()[1] otherwise we can just unwrap
            -- *ptr[1] -> *ptr.unwrap()[1]
            if cfg:is_opt_any() then
                if cfg:is_opt_box_any() or cfg.extra_data.mutability == "mut" then
                    unwrapped_expr:to_method_call("as_mut", {unwrapped_expr})
                end
                unwrapped_expr:to_method_call("unwrap", {unwrapped_expr})
            end
        else
            log_error("Found offset method applied to a reference: " .. tostring(expr))
            return
        end

        -- A cast to isize may have been applied by translator for offset(x)
        -- We should convert it to usize for the index
        if offset_expr:get_kind() == "Cast" then
            local cast_expr = offset_expr:get_exprs()[1]
            local cast_ty = offset_expr:get_ty()

            if cast_ty:get_kind() == "Path" and cast_ty:get_path():get_segments()[1] == "isize" then
                cast_ty:to_simple_path("usize")

                offset_expr:set_ty(cast_ty)
            end
        end

        expr:to_index(unwrapped_expr, offset_expr)
    -- *ptr = 1 -> **ptr.as_mut().unwrap() = 1
    elseif unwrapped_expr:get_kind() == "Path" then
        local cfg = self:get_expr_cfg(unwrapped_expr)

        if not cfg then return end

        -- If we're using an option, we must unwrap
        -- Must get inner reference to mutate
        if cfg:is_opt_any() then
            local is_mut = cfg:is_mut()

            -- as_ref is not required for immutable refs since &T is Copy
            if is_mut or cfg:is_box_any() then
                unwrapped_expr:to_method_call("as_mut", {unwrapped_expr})
            end

            expr:to_method_call("unwrap", {unwrapped_expr})

            -- Slices need to be indexed at 0 to equate to a ptr deref
            -- *a -> a.unwrap()[0] but thin refs can just be deref'd.
            -- *a -> *a.unwrap()
            if cfg:is_slice_any() then
                local zero_expr = self.tctx:int_lit_expr(0, nil)
                expr:to_index(expr, zero_expr)
            else
                -- For immut refs we skip the superflous as_ref call,
                -- so we can also skip one of the corresponding derefs
                if is_mut or cfg:is_box_any() then
                    expr:to_unary("Deref", expr)
                end

                expr:to_unary("Deref", expr)
            end
        -- Slices need to be indexed at 0 to equate to a ptr deref
        -- *a -> a.unwrap()[0] but thin refs can just be deref'd.
        -- *a -> *a.unwrap()
        elseif cfg:is_slice_any() then
            local zero_expr = self.tctx:int_lit_expr(0, nil)
            expr:to_index(unwrapped_expr, zero_expr)
        end
    end
end

function Visitor:rewrite_assign_expr(expr)
    local exprs = expr:get_exprs()
    local lhs = exprs[1]
    local rhs = exprs[2]
    local rhs_kind = rhs:get_kind()
    local hirid = self.tctx:resolve_path_hirid(lhs)
    local var = self:get_var(hirid)

    if rhs_kind == "Cast" then
        local cast_expr = rhs:get_exprs()[1]
        local cast_ty = rhs:get_ty()

        -- p = malloc(X) as *mut T -> p = Some(vec![0; X / size_of<T>].into_boxed_slice())
        -- or p = vec![0; X / size_of<T>].into_boxed_slice()
        if cast_ty:get_kind() == "Ptr" and cast_expr:get_kind() == "Call" then
            local call_exprs = cast_expr:get_exprs()
            local path_expr = call_exprs[1]
            local param_expr = call_exprs[2]
            local path = path_expr:get_path()
            local segments = path:get_segments()
            local conversion_cfg = var and self.node_id_cfgs[var.id]

            -- In case malloc is called from another module check the last segment
            if conversion_cfg and segments[#segments] == "malloc" then
                local mut_ty = cast_ty:get_mut_ty()
                local pointee_ty = mut_ty:get_ty()
                local new_rhs = nil
                -- TODO: zero-init will only work for numbers, not structs/unions
                local init = self.tctx:int_lit_expr(0, nil)

                -- For slices we want to use vec![init; num].into_boxed_slice
                if conversion_cfg:is_slice_any() then
                    path:set_segments{"", "core", "mem", "size_of"}
                    path:set_generic_angled_arg_tys(4, {pointee_ty})
                    path_expr:to_path(path)
                    path_expr:to_call{path_expr}

                    local usize_ty = self.tctx:ident_path_ty("usize")
                    local cast_expr = self.tctx:cast_expr(param_expr, usize_ty)
                    local binary_expr = self.tctx:binary_expr("Div", cast_expr, path_expr)

                    new_rhs = self.tctx:vec_mac_init_num(init, binary_expr)
                    new_rhs:to_method_call("into_boxed_slice", {new_rhs})
                -- For boxes we want Box::new(init)
                elseif conversion_cfg:is_box_any() then
                    path:set_segments{"Box", "new"}
                    path_expr:to_path(path)
                    path_expr:to_call{path_expr, init}

                    new_rhs = path_expr
                end

                -- Only wrap in Some if we're assigning to an opt variable
                if conversion_cfg:is_opt_any() then
                    local some_path_expr = self.tctx:ident_path_expr("Some")
                    rhs:to_call{some_path_expr, new_rhs}
                else
                    rhs = new_rhs
                end

                expr:set_exprs{lhs, rhs}
            end
        -- p = 0 as *mut/const T -> p = None
        elseif is_null_ptr(rhs) then
            local conversion_cfg = self:get_expr_cfg(lhs)

            if conversion_cfg and conversion_cfg:is_opt_any() then
                rhs:to_ident_path("None")
                expr:set_exprs{lhs, rhs}
            end
        end
    -- lhs = rhs -> lhs = Some(rhs)
    elseif rhs_kind == "Path" then
        local lhs_cfg = self:get_expr_cfg(lhs)
        local rhs_cfg = self:get_expr_cfg(rhs)

        if not rhs_cfg then return end

        if not rhs_cfg:is_opt_any() then
            local lhs_ty = self.tctx:get_expr_ty(lhs)

            -- If lhs was a ptr, and rhs isn't wrapped in some, wrap it
            -- TODO: Validate rhs needs to be wrapped
            if lhs_ty:get_kind() == "Ptr" then
                local some_path_expr = self.tctx:ident_path_expr("Some")

                rhs:to_call{some_path_expr, rhs}
                expr:set_exprs{lhs, rhs}
            end
        end

        if lhs_cfg then
            lhs_cfg.extra_data.non_null_wrapped = rhs_cfg.extra_data.non_null_wrapped
        end
    else
        local lhs_cfg = self:get_expr_cfg(lhs)

        if not lhs_cfg then return end

        if lhs_cfg:is_opt_any() then
            if rhs_kind == "Call" then
                local path_expr = rhs:get_exprs()[1]
                local path = path_expr:get_path()

                path:set_segments{"", "core", "ptr", "NonNull", "new"}
                path_expr:to_path(path)

                rhs:to_call{path_expr, rhs}
                expr:set_exprs{lhs, rhs}

                lhs_cfg.extra_data.non_null_wrapped = true

                return
            end

            local some_path_expr = self.tctx:ident_path_expr("Some")
            rhs:to_call{some_path_expr, rhs}
            expr:set_exprs{lhs, rhs}
        end
    end
end

-- free(foo.bar as *mut libc::c_void) -> foo.bar.take()
function Visitor:rewrite_call_expr(expr)
    local call_exprs = expr:get_exprs()
    local path_expr = call_exprs[1]
    local first_param_expr = call_exprs[2]
    local path = path_expr:get_path()
    local segments = path and path:get_segments()

    -- In case free is called from another module check the last segment
    if segments and segments[#segments] == "free" and first_param_expr:get_kind() == "Cast" then
        -- REVIEW: What if there's a multi-layered cast?
        local uncasted_expr = first_param_expr:get_exprs()[1]
        local cast_ty = first_param_expr:get_ty()
        local cfg = self:get_expr_cfg(uncasted_expr)

        if cfg and cfg:is_opt_any() then
            expr:to_method_call("take", {uncasted_expr})

            -- If it's not also boxed, then we probably have an inner raw ptr
            -- and should still call free on it
            if not cfg:is_box_any() then
                uncasted_expr = decay_ref_to_ptr(expr, cfg)
                uncasted_expr:to_cast(uncasted_expr, cast_ty)
                expr:to_call{path_expr, uncasted_expr}
            end
        end
    -- ip as *mut c_void -> ip.as_mut_ptr() as *mut c_void
    -- Though this should be expanded to support other exprs like
    -- fields
    elseif segments and segments[#segments] == "memset" then
        first_param_expr:filtermap_subexprs(
            function(expr_kind) return expr_kind == "Path" end,
            function(expr)
                local cfg = self:get_expr_cfg(expr)

                if cfg and cfg:is_box_any() then
                    expr:to_method_call("as_mut_ptr", {expr})
                end

                return expr
            end
        )

        call_exprs[2] = first_param_expr

        expr:set_exprs(call_exprs)
    -- Skip; handled elsewhere by local conversion
    elseif segments and segments[#segments] == "malloc" then
    -- Generic function call param conversions
    -- NOTE: Some(x) counts as a function call on x, so we skip Some
    -- so as to not recurse when we generate that expr
    elseif segments and segments[#segments] ~= "Some" then
        local hirid = self.tctx:resolve_path_hirid(path_expr)
        local fn = self:get_fn(hirid)

        if not fn then return end

        for i, param_expr in ipairs(call_exprs) do
            -- Skip function name path expr
            if i == 1 then goto continue end

            local param_cfg = self:get_param_cfg(fn, i - 1)
            local param_kind = param_expr:get_kind()

            -- static.as_ptr/as_mut_ptr() -> &static/&mut static
            -- &static/&mut static -> Option<&static/&mut static>
            if param_cfg and param_kind == "MethodCall" then
                local exprs = param_expr:get_exprs()
                local path_expr = exprs[1]

                if #exprs == 1 and path_expr:get_kind() == "Path" then
                    local method_name = param_expr:get_method_name()

                    if method_name == "as_ptr" then
                        param_expr:to_addr_of(path_expr, false)
                    elseif method_name == "as_mut_ptr" then
                        param_expr:to_addr_of(path_expr, true)
                    end

                    if param_cfg:is_opt_any() then
                        local some_path_expr = self.tctx:ident_path_expr("Some")
                        param_expr:to_call{some_path_expr, param_expr}
                    end

                    goto continue
                end
            end

            if param_cfg and param_cfg:is_opt_any() then
                -- 0 as *const/mut T -> None
                if is_null_ptr(param_expr) then
                    param_expr:to_ident_path("None")
                    goto continue
                -- &T -> Some(&T)
                elseif param_kind == "AddrOf" then
                    local some_path_expr = self.tctx:ident_path_expr("Some")
                    param_expr:to_call{some_path_expr, param_expr}

                    goto continue
                elseif param_kind == "Path" then
                    local path_cfg = self:get_expr_cfg(param_expr)

                    if path_cfg then
                        -- path -> Some(path)
                        if not path_cfg:is_opt_any() then
                            local some_path_expr = self.tctx:ident_path_expr("Some")
                            param_expr:to_call{some_path_expr, param_expr}
                        -- Decay mut ref to immut ref inside option
                        -- foo(x) -> foo(x.as_ref().map(|r| &**r))
                        elseif path_cfg:is_mut() and not param_cfg:is_mut() then
                            local var_expr = self.tctx:ident_path_expr("r")

                            var_expr:to_unary("Deref", var_expr)
                            var_expr:to_unary("Deref", var_expr)
                            var_expr:to_addr_of(var_expr, false)

                            var_expr:to_closure({"r"}, var_expr)
                            param_expr:to_method_call("as_ref", {param_expr})
                            param_expr:to_method_call("map", {param_expr, var_expr})
                        end

                        goto continue
                    end
                end
            end

            -- Avoid nested call exprs
            if param_kind == "Call" then
                goto continue
            end

            --  x -> x[.as_mut()].unwrap().as_[mut_]ptr()
            param_expr:filtermap_subexprs(
                function(expr_kind) return expr_kind == "Unary" or expr_kind == "Path" end,
                function(expr)
                    -- Deref exprs should already be handled by rewrite_deref_expr
                    -- so we should skip over them (maybe only if derefing path?)
                    if expr:get_op() == "Deref" then
                        return expr
                    end

                    local cfg = self:get_expr_cfg(expr)

                    if not cfg then
                        return expr
                    end

                    if fn.is_foreign then
                        expr = decay_ref_to_ptr(expr, cfg)
                    else
                        -- TODO: Conversion to converted signatures
                    end

                    return expr
                end
            )

            ::continue::
        end

        expr:set_exprs(call_exprs)
    end
end

function Visitor:get_expr_cfg(expr)
    local hirid = self.tctx:resolve_path_hirid(expr)
    local node_id = nil
    local var = self:get_var(hirid)

    -- If we're looking at a local or param, lookup from the variable map
    if var then
        node_id = var.id
    -- Otherwise check the field map
    elseif expr:get_kind() == "Field" then
        hirid = self.tctx:get_field_expr_hirid(expr)
        local field = self:get_field(hirid)

        if field then
            node_id = field.id
        end
    end

    return self.node_id_cfgs[node_id]
end

-- HrIds may be reused in different functions, so we should clear them out
-- so we don't accidentally access old info
-- NOTE: If this script encounters any nested functions, this will reset variables
-- prematurely. We should push and pop a stack of variable scopes to account for this
function Visitor:clear_nonstatic_vars()
    local static_vars = {}

    for hirid, var in pairs(self.vars) do
        if var.kind == "static" then
            static_vars[hirid] = var
        end
    end

    self.vars = static_vars
end

function Visitor:flat_map_item(item, walk)
    local item_kind = item:get_kind()

    if item_kind == "Struct" then
        local lifetimes = OrderedMap()
        local fields = item:get_fields()
        local is_copy = true

        for _, field in ipairs(fields) do
            local field_id = field:get_id()
            local cfg = self.node_id_cfgs[field_id]
            local field_hrid = self.tctx:nodeid_to_hirid(field_id)

            self:add_field(field_hrid, Field.new(field_id))

            if cfg then
                if cfg:is_box_any() then
                    is_copy = false
                end

                if cfg.extra_data.lifetime then
                    item:add_lifetime(cfg.extra_data.lifetime)

                    lifetimes[cfg.extra_data.lifetime] = true
                end
            end
        end

        if not is_copy then
            -- TODO: Remove Copy from non Copy structs
            -- item:clear_derives()
        end

        local hirid = self.tctx:nodeid_to_hirid(item:get_id())

        self:add_struct(hirid, Struct.new(lifetimes, is_copy))
    elseif item_kind == "Fn" then
        self:clear_nonstatic_vars()

        local args = item:get_args()
        local arg_ids = {}

        for i, arg in ipairs(args) do
            local arg_id = arg:get_id()
            local ref_cfg = self.node_id_cfgs[arg_id]

            table.insert(arg_ids, arg_id)

            if ref_cfg and ref_cfg.extra_data.lifetime then
                item:add_lifetime(ref_cfg.extra_data.lifetime)
            end

            local arg_ty = arg:get_ty()

            -- Grab lifetimes from the argument type
            -- REVIEW: Maybe this shouldn't map but just traverse?
            arg_ty:map_ptr_root(function(path_ty)
                if path_ty:get_kind() ~= "Path" then
                    return path_ty
                end

                local hirid = self.tctx:resolve_ty_hirid(path_ty)
                local struct = self:get_struct(hirid)

                if struct then
                    for lifetime in struct.lifetimes:iter() do
                        path_ty:add_lifetime(lifetime)
                        item:add_lifetime(lifetime)
                    end
                end

                return path_ty
            end)

            arg:set_ty(arg_ty)

            -- TODO: Possibly move visit_arg into here?
        end

        item:set_args(args)

        local fn_id = item:get_id()
        local hirid = self.tctx:nodeid_to_hirid(fn_id)

        self:add_fn(hirid, Fn.new(fn_id, false, arg_ids))
    elseif item_kind == "Static" then
        local hirid = self.tctx:nodeid_to_hirid(item:get_id())

        self:add_var(hirid, Variable.new(item:get_id(), "static"))
    -- elseif item_kind == "Impl" then
    --     local seg = item:get_trait_ref():get_segments()
    --     print(seg[#seg])

    --     if seg == "Copy" then
    --         return {}
    --     end
    end

    walk(item)

    return {item}
end

function Visitor:flat_map_foreign_item(foreign_item)
    if foreign_item:get_kind() == "Fn" then
        local fn_id = foreign_item:get_id()
        local hirid = self.tctx:nodeid_to_hirid(fn_id)

        self:add_fn(hirid, Fn.new(fn_id, true, {}))
    end

    return {foreign_item}
end

function Visitor:flat_map_stmt(stmt, walk)
    local stmt_kind = stmt:get_kind()
    local cfg = self.node_id_cfgs[stmt:get_id()]

    if not cfg then
        walk(stmt)
        return {stmt}
    end

    if cfg:is_del() then
        return {}
    elseif cfg:is_byteswap() and stmt:get_kind() == "Semi" then
        local expr = stmt:get_node()
        local lhs_id = cfg.extra_data[1]
        local rhs_id = cfg.extra_data[2]
        local lhs = expr:find_subexpr(lhs_id)
        local rhs = expr:find_subexpr(rhs_id)

        if lhs and rhs then
            rhs:to_method_call("swap_bytes", {rhs})

            local assign_expr = self.tctx:assign_expr(lhs, rhs)

            stmt:to_semi(assign_expr)
        end
    end

    walk(stmt)

    return {stmt}
end

function Visitor:flat_map_struct_field(field)
    local field_id = field:get_id()
    local field_ty = field:get_ty()
    local cfg = self.node_id_cfgs[field_id]

    if not cfg then return end

    local field_ty_kind = field_ty:get_kind()

    -- *mut T -> Box<T>, or Box<[T]> or Option<Box<T>> or Option<Box<[T]>>
    if field_ty_kind == "Ptr" then
        field:set_ty(upgrade_ptr(field_ty, cfg))
    -- [*mut T; X] -> [Box<T>; X] or [Box<[T]>; X] or [Option<Box<T>>; X]
    -- or [Option<Box<[T]>; X]
    elseif field_ty_kind == "Array" then
        local inner_ty = field_ty:get_tys()[1]

        if inner_ty:get_kind() == "Ptr" then
            inner_ty = upgrade_ptr(inner_ty, cfg)

            field_ty:set_tys{inner_ty}
            field:set_ty(field_ty)
        end
    end

    return {field}
end

function is_null_ptr(expr)
    if expr and expr:get_kind() == "Cast" then
        local cast_expr = expr:get_exprs()[1]
        local cast_ty = expr:get_ty()

        if cast_expr:get_kind() == "Lit" then
            local lit = cast_expr:get_node()

            if lit and lit:get_value() == 0 and cast_ty:get_kind() == "Ptr" then
                return true
            end
        end
    end

    return false
end

function is_void_ptr(ty)
    if ty:get_kind() == "Ptr" then
        local mut_ty = ty:get_mut_ty()
        local pointee_ty = mut_ty:get_ty()
        local path = pointee_ty:get_path()

        if path then
            local segments = path:get_segments()

            if segments[#segments] == "c_void" then
                return true
            end
        end

        return is_void_ptr(pointee_ty)
    end

    return false
end

function Visitor:visit_local(locl)
    local local_id = locl:get_id()
    local cfg = self.node_id_cfgs[local_id]

    if not cfg then return end

    local init = locl:get_init()

    if init:get_kind() == "Path" then
        local rhs_cfg = self:get_expr_cfg(init)

        if rhs_cfg then
            locl:set_ty(nil)
        end
    -- let x: *mut T = 0 as *mut T; -> let mut x = None;
    -- or let mut x;
    elseif cfg:is_opt_any() and is_null_ptr(init) then
        init:to_ident_path("None")

        locl:set_ty(nil)
        locl:set_init(init)
    elseif is_null_ptr(init) then
        locl:set_ty(nil)
        locl:set_init(nil)
    end

    local pat_hirid = self.tctx:nodeid_to_hirid(locl:get_pat_id())

    self:add_var(pat_hirid, Variable.new(local_id, "local"))
end

-- The MarkConverter takes marks and processes them into ConvCfgs
MarkConverter = {}

function MarkConverter.new(marks, boxes, tctx)
    self = {}
    self.marks = marks
    self.node_id_cfgs = {}
    self.boxes = boxes
    self.tctx = tctx

    setmetatable(self, MarkConverter)
    MarkConverter.__index = MarkConverter

    return self
end

function MarkConverter:flat_map_param(arg)
    local arg_id = arg:get_id()
    local arg_ty = arg:get_ty()
    local arg_ty_id = arg_ty:get_id()
    local marks = self.marks[arg_ty_id] or {}

    -- Skip over args likely from extern fns
    if arg:get_pat():get_kind() == "Wild" then
        return {arg}
    end

    -- Skip over pointers to void
    if is_void_ptr(arg_ty) then
        return {arg}
    end

    -- Skip if there are no marks
    if next(marks) == nil then return end

    local attrs = arg:get_attrs()

    -- TODO: Box support
    self.node_id_cfgs[arg_id] = ConvCfg.from_marks(marks, attrs)
end

function MarkConverter:visit_local(locl)
    local ty = locl:get_ty()

    -- Locals with no type annotation are skipped
    if not ty then return end

    local ty_id = ty:get_id()
    local id = locl:get_id()
    local pat_hirid = self.tctx:nodeid_to_hirid(locl:get_pat_id())
    local marks = self.marks[ty_id] or {}
    local attrs = locl:get_attrs()

    if self.boxes[tostring(pat_hirid)] then
        marks["box"] = true
    end

    -- Skip if there are no marks
    if next(marks) == nil then return end

    self.node_id_cfgs[id] = ConvCfg.from_marks(marks, attrs)
end

function MarkConverter:flat_map_item(item, walk)
    local item_kind = item:get_kind()
    local crate_vis = item:get_vis() == "Crate"

    if item_kind == "Struct" and crate_vis then
        local fields = item:get_fields()

        for _, field in ipairs(fields) do
            local field_id = field:get_id()
            local field_ty = field:get_ty()
            local ty_id = field_ty:get_id()

            if field_ty:get_kind() == "Array" then
                ty_id = field_ty:get_tys()[1]:get_id()
            end

            local marks = self.marks[ty_id] or {}

            if next(marks) ~= nil then
                self.node_id_cfgs[field_id] = ConvCfg.from_marks(marks, field:get_attrs())
            end
        end
    end

    walk(item)

    return {item}
end

-- This visitor finds variables that are assigned
-- a malloc or calloc and marks them as "box"
MallocMarker = {}

function MallocMarker.new(tctx)
    self = {}
    self.tctx = tctx
    self.boxes = {}

    setmetatable(self, MallocMarker)
    MallocMarker.__index = MallocMarker

    return self
end

function MallocMarker:visit_expr(expr)
    local expr_kind = expr:get_kind()

    -- Mark types as "box" for malloc/calloc
    if expr_kind == "Assign" then
        local exprs = expr:get_exprs()
        local lhs = exprs[1]
        local rhs = exprs[2]
        local rhs_kind = rhs:get_kind()
        local hirid = self.tctx:resolve_path_hirid(lhs)

        if rhs_kind == "Cast" then
            local cast_expr = rhs:get_exprs()[1]
            local cast_ty = rhs:get_ty()

            if cast_ty:get_kind() == "Ptr" and cast_expr:get_kind() == "Call" then
                local call_exprs = cast_expr:get_exprs()
                local path_expr = call_exprs[1]
                local path = path_expr:get_path()
                local segments = path:get_segments()

                -- In case malloc is called from another module check the last segment
                if segments[#segments] == "malloc" or segments[#segments] == "calloc" then
                    -- TODO: Non path support. IE Field
                    self.boxes[tostring(hirid)] = true
                end
            end
        end
    end

    return {arg}
end

function infer_node_id_cfgs(tctx)
    local marks = tctx:get_marks()
    local malloc_marker = MallocMarker.new(tctx)

    tctx:visit_crate_new(malloc_marker)

    local converter = MarkConverter.new(marks, malloc_marker.boxes, tctx)
    tctx:visit_crate_new(converter)
    return converter.node_id_cfgs
end

function run_ptr_upgrades(node_id_cfgs)
    if not node_id_cfgs then
        refactor:run_command("select", {"target", "crate; desc(fn || field);"})
        -- refactor:run_command("ownership_annotate", {"target"})
        refactor:run_command("ownership_mark_pointers", {})
        -- refactor:dump_marks()
    end

    refactor:transform(
        function(transform_ctx)
            if not node_id_cfgs then
                node_id_cfgs = infer_node_id_cfgs(transform_ctx)
                -- pretty.dump(node_id_cfgs)
            end
            return transform_ctx:visit_crate_new(Visitor.new(transform_ctx, node_id_cfgs))
        end
    )
end

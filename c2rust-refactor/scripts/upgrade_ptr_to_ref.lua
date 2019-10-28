require "pl"

-- Take a set of node ids (locals/params/fields) and turn them (if a pointer)
-- into a reference or Box
Variable = {}

function Variable.new(node_id, is_locl)
    self = {}
    self.id = node_id
    self.is_locl = is_locl
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

function Struct.new(lifetimes)
    self = {}
    self.lifetimes = lifetimes

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

function ConvCfg.from_mark(mark, attrs)
    local opt = true
    local slice = false
    local mutability = nil
    local binding = nil
    local conv_type = ""

    for _, attr in ipairs(attrs) do
        local attr_ident = attr:ident()

        if attr_ident == "nonnull" then
            opt = false
        elseif attr_ident == "slice" then
            slice = true
        end
    end

    if opt then
        conv_type = "opt_"
    end

    if mark == "ref" then
        mutability = "immut"

        if slice then
            conv_type = conv_type .. "slice"
        else
            conv_type = conv_type .. "ref"
        end
    elseif mark == "mut" then
        mutability = "mut"
        binding = "ByValMut"

        if slice then
            conv_type = conv_type .. "slice"
        else
            conv_type = conv_type .. "ref"
        end
    elseif mark == "box" then
        conv_type = conv_type .. "box"

        if slice then
            conv_type = conv_type .. "_slice"
        end
    end

    if conv_type == "" or conv_type[#conv_type] == "_" then
        log_error("Could not build appropriate conversion cfg for: " .. tostring(arg))
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
    -- PatHrId -> Variable
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

            self:add_var(arg_pat_hrid, Variable.new(arg_id, false))

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
    -- p.is_null() -> p.is_none() or false when not using an option
    elseif expr:get_method_name() == "is_null" then
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
    elseif expr_kind == "Assign" then
        self:rewrite_assign_expr(expr)
    elseif expr_kind == "Call" then
        self:rewrite_call_expr(expr)
    end
end

function Visitor:rewrite_field_expr(expr)
    local field_expr = expr:get_exprs()[1]

    if field_expr:get_kind() == "Unary" and field_expr:get_op() == "Deref" then
        local derefed_expr = field_expr:get_exprs()[1]

        if derefed_expr:get_kind() == "Path" then
            local hirid = self.tctx:resolve_path_hirid(derefed_expr)
            local var = self:get_var(hirid)
            local cfg = var and self.node_id_cfgs[var.id]

            -- This is a path we're expecting to modify
            if not cfg then
                return
            end

            -- (*foo).bar -> (*foo).as_mut().unwrap().bar
            if cfg:is_opt_any() then
                local as_x = get_as_x(cfg.extra_data.mutability)

                derefed_expr:to_method_call(as_x, {derefed_expr})
                derefed_expr:to_method_call("unwrap", {derefed_expr})
            end

            -- (*foo).bar -> (foo).bar (can't remove parens..)
            expr:set_exprs{derefed_expr}
        end
    end
end

function Visitor:rewrite_deref_expr(expr)
    local derefed_exprs = expr:get_exprs()
    local unwrapped_expr = derefed_exprs[1]

    -- *p.offset(x).offset(y) -> p[x + y] (pointer) or
    -- *p.as_mut_ptr().offset(x).offset(y) -> p[x + y] (array)
    if unwrapped_expr:get_method_name() == "offset" then
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
                -- TODO: or as_ref
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
        local hirid = self.tctx:resolve_path_hirid(unwrapped_expr)
        local var = self:get_var(hirid)

        if not var then
            return
        end

        -- If we're using an option, we must unwrap
        -- Must get inner reference to mutate (or map/match)
        if self.node_id_cfgs[var.id]:is_opt_any() then
            local as_x = nil

            if self.node_id_cfgs[var.id].extra_data.mutability == "immut" then
                as_x = "as_ref"
            else
                as_x = "as_mut"
            end

            unwrapped_expr:to_method_call(as_x, {unwrapped_expr})
            expr:to_method_call("unwrap", {unwrapped_expr})
            expr:to_unary("Deref", expr)
            expr:to_unary("Deref", expr)
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
    -- TODO: Should probably expand to work on more complex exprs
    elseif rhs_kind == "Path" then
        local hirid = self.tctx:resolve_path_hirid(rhs)
        local var = self:get_var(hirid)

        if var and not self.node_id_cfgs[var.id]:is_opt_any() then
            local lhs_ty = self.tctx:get_expr_ty(lhs)

            -- If lhs was a ptr, and rhs isn't wrapped in some, wrap it
            -- TODO: Validate rhs needs to be wrapped
            if lhs_ty:get_kind() == "Ptr" then
                local some_path_expr = self.tctx:ident_path_expr("Some")

                rhs:to_call{some_path_expr, rhs}
                expr:set_exprs{lhs, rhs}
            end
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
        local conversion_cfg = self:get_expr_cfg(uncasted_expr)

        if conversion_cfg and conversion_cfg:is_opt_any() then
            expr:to_method_call("take", {uncasted_expr})
        end
    -- ip as *mut c_void -> ip.as_mut_ptr() as *mut c_void
    -- Though this should be expanded to support other exprs like
    -- fields
    elseif segments and segments[#segments] == "memset" then
        first_param_expr:map_first_path(function(path_expr)
            local cfg = self:get_expr_cfg(path_expr)

            if cfg and cfg:is_box_any() then
                path_expr:to_method_call("as_mut_ptr", {path_expr})
            end

            return path_expr
        end)

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
                -- path -> Some(path)
                elseif param_kind == "Path" then
                    local path_cfg = self:get_expr_cfg(param_expr)

                    if path_cfg and not path_cfg:is_opt_any() then
                        local some_path_expr = self.tctx:ident_path_expr("Some")
                        param_expr:to_call{some_path_expr, param_expr}

                        goto continue
                    end
                end
            end

            -- x.unwrap() or x.as_mut().unwrap()
            param_expr:map_first_path(function(path_expr)
                local cfg = self:get_expr_cfg(path_expr)

                if not cfg then
                    return path_expr
                end

                if fn.is_foreign then
                    -- TODO: Should base decay on mutability of param not
                    -- the variable
                    -- TODO: This may need tweaking for boxed locals
                    local as_x = get_as_x(cfg.extra_data.mutability)
                    local as_x_ptr = get_x_ptr(cfg.extra_data.mutability)

                    if cfg:is_opt_any() then
                        if as_x == "as_mut" then
                            path_expr:to_method_call("as_mut", {path_expr})
                        end

                        path_expr:to_method_call("unwrap", {path_expr})

                        if cfg:is_slice_any() then
                            path_expr:to_method_call(as_x_ptr, {path_expr})
                        elseif as_x == "as_mut" then
                            path_expr:to_unary("Deref", path_expr)
                        end
                    elseif cfg:is_slice_any() then
                        path_expr:to_method_call(as_x_ptr, {path_expr})
                    end
                else
                    -- TODO: Conversion to converted signatures
                end

                return path_expr
            end)

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
function Visitor:visit_fn_decl(fn_decl)
    self.vars = {}
end

function Visitor:flat_map_item(item, walk)
    local item_kind = item:get_kind()
    print("Item:", item:get_id(), item_kind)

    if item_kind == "Struct" then
        local lifetimes = OrderedMap()
        local field_ids = item:get_field_ids()

        for _, field_id in ipairs(field_ids) do
            local ref_cfg = self.node_id_cfgs[field_id]
            local field_hrid = self.tctx:nodeid_to_hirid(field_id)

            self:add_field(field_hrid, Field.new(field_id))

            if ref_cfg and ref_cfg.extra_data.lifetime then
                item:add_lifetime(ref_cfg.extra_data.lifetime)

                lifetimes[ref_cfg.extra_data.lifetime] = true
            end
        end

        local hirid = self.tctx:nodeid_to_hirid(item:get_id())

        self:add_struct(hirid, Struct.new(lifetimes))
    elseif item_kind == "Fn" then
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
    local conversion_cfg = self.node_id_cfgs[field_id]

    if conversion_cfg then
        local field_ty_kind = field_ty:get_kind()

        -- *mut T -> Box<T>, or Box<[T]> or Option<Box<T>> or Option<Box<[T]>>
        if field_ty_kind == "Ptr" then
            field:set_ty(upgrade_ptr(field_ty, conversion_cfg))
        -- [*mut T; X] -> [Box<T>; X] or [Box<[T]>; X] or [Option<Box<T>>; X]
        -- or [Option<Box<[T]>; X]
        elseif field_ty_kind == "Array" then
            local inner_ty = field_ty:get_tys()[1]

            if inner_ty:get_kind() == "Ptr" then
                inner_ty = upgrade_ptr(inner_ty, conversion_cfg)

                field_ty:set_tys{inner_ty}
                field:set_ty(field_ty)
            end
        end
    end

    return {field}
end

function get_as_x(mutability)
    if mutability == "immut" then
        return "as_ref"
    elseif mutability == "mut" then
        return "as_mut"
    else
        log_error("[get_as_x] Found unknown mutability: " .. tostring(mutability))
    end
end

function get_x_ptr(mutability)
    if mutability == "immut" then
        return "as_ptr"
    elseif mutability == "mut" then
        return "as_mut_ptr"
    else
        log_error("[get_x_ptr] Found unknown mutability: " .. tostring(mutability))
    end
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
    local conversion_cfg = self.node_id_cfgs[local_id]

    -- let x: *mut T = 0 as *mut T; -> let mut x = None;
    -- or let mut x;
    if conversion_cfg then
        if conversion_cfg:is_opt_any() then
            local init = locl:get_init()

            if is_null_ptr(init) then
                init:to_ident_path("None")

                locl:set_ty(nil)
                locl:set_init(init)
            end
        elseif conversion_cfg:is_box_any() then
            local init = locl:get_init()

            if is_null_ptr(init) then
                locl:set_ty(nil)
                locl:set_init(nil)
            end
        end

        local pat_hirid = self.tctx:nodeid_to_hirid(locl:get_pat_id())

        self:add_var(pat_hirid, Variable.new(local_id, true))
    end
end

MarkConverter = {}

function MarkConverter.new(marks)
    self = {}
    self.marks = marks
    self.node_id_cfgs = {}

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

    local attrs = arg:get_attrs()

    for _, mark in ipairs(marks) do
        self.node_id_cfgs[arg_id] = ConvCfg.from_mark(mark, attrs)
    end
end

function MarkConverter:visit_local(locl)
    local ty = locl:get_ty()
    local ty_id = ty:get_id()
    local id = locl:get_id()
    local marks = self.marks[ty_id] or {}

    for _, mark in ipairs(marks) do
        self.node_id_cfgs[id] = ConvCfg.from_mark(mark, {})
    end

    return {arg}
end

function infer_node_id_cfgs(ctx)
    local marks = ctx:get_marks()
    local converter = MarkConverter.new(marks)
    ctx:visit_crate_new(converter)
    return converter.node_id_cfgs
end

function run_ptr_upgrades(node_id_cfgs)
    if not node_id_cfgs then
        refactor:run_command("select", {"target", "crate; desc(fn || field);"})
        -- refactor:run_command("ownership_annotate", {"target"})
        refactor:run_command("ownership_mark_pointers", {})
    end

    refactor:transform(
        function(transform_ctx)
            if not node_id_cfgs then
                node_id_cfgs = infer_node_id_cfgs(transform_ctx)
            end
            return transform_ctx:visit_crate_new(Visitor.new(transform_ctx, node_id_cfgs))
        end
    )
end

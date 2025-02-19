use std::collections::HashMap;
use syntax::ast::*;
use syntax::attr::HasAttrs;
use syntax::mut_visit::{self, MutVisitor};
use syntax::ptr::P;
use syntax::visit::{self, Visitor};
use syntax_pos::sym;

use smallvec::SmallVec;

use crate::ast_manip::{GetNodeId, MutVisit, Visit};

struct CollectCfgAttrs {
    node_attrs: HashMap<NodeId, Vec<Attribute>>,
}

impl CollectCfgAttrs {
    fn collect<T: HasAttrs + GetNodeId>(&mut self, x: &T) {
        let attrs = x
            .attrs()
            .iter()
            .filter(|attr| attr.check_name(sym::cfg_attr))
            .cloned()
            .collect::<Vec<_>>();
        if attrs.len() > 0 {
            self.node_attrs.insert(x.get_node_id(), attrs);
        }
    }
}

macro_rules! collect_cfg_attrs {
    ($($visit_thing:ident($Thing:ty), $walk_thing:ident;)*) => {
        impl<'ast> Visitor<'ast> for CollectCfgAttrs {
            $(
                fn $visit_thing(&mut self, x: &'ast $Thing) {
                    self.collect(x);
                    visit::$walk_thing(self, x);
                }
            )*

            fn visit_mac(&mut self, mac: &'ast Mac) {
                visit::walk_mac(self, mac)
            }
        }
    };
}

collect_cfg_attrs! {
    visit_item(Item), walk_item;
    visit_impl_item(ImplItem), walk_impl_item;
    visit_trait_item(TraitItem), walk_trait_item;
    visit_foreign_item(ForeignItem), walk_foreign_item;
    visit_stmt(Stmt), walk_stmt;
    visit_expr(Expr), walk_expr;
    // TODO: extend this list with the remaining node types
}

pub fn collect_cfg_attrs(krate: &Crate) -> HashMap<NodeId, Vec<Attribute>> {
    let mut v = CollectCfgAttrs {
        node_attrs: HashMap::new(),
    };
    krate.visit(&mut v);
    v.node_attrs
}

struct RestoreCfgAttrs {
    node_attrs: HashMap<NodeId, Vec<Attribute>>,
}

impl RestoreCfgAttrs {
    fn restore<T: HasAttrs + GetNodeId>(&mut self, x: &mut T) {
        if let Some(cfg_attrs) = self.node_attrs.get(&x.get_node_id()) {
            info!(
                "RESTORE ATTRS {:?} onto {:?}",
                cfg_attrs
                    .iter()
                    .map(|a| ::syntax::print::pprust::attribute_to_string(a))
                    .collect::<Vec<_>>(),
                x.attrs()
                    .iter()
                    .map(|a| ::syntax::print::pprust::attribute_to_string(a))
                    .collect::<Vec<_>>()
            );
            x.visit_attrs(|attrs| {
                // Drop attrs that were produced by evaluation of one of the `#[cfg_attr]`s.
                attrs.retain(|a| !cfg_attrs.iter().any(|ca| ca.span.contains(a.span)));
                // Now put the #[cfg_attr]s themselves back in.
                attrs.extend(cfg_attrs.iter().cloned());
            });
            info!(
                "  attrs changed to {:?}",
                x.attrs()
                    .iter()
                    .map(|a| ::syntax::print::pprust::attribute_to_string(a))
                    .collect::<Vec<_>>()
            );
        }
    }
}

impl MutVisitor for RestoreCfgAttrs {
    fn flat_map_item(&mut self, mut i: P<Item>) -> SmallVec<[P<Item>; 1]> {
        self.restore(&mut i);
        mut_visit::noop_flat_map_item(i, self)
    }

    fn flat_map_impl_item(&mut self, mut i: ImplItem) -> SmallVec<[ImplItem; 1]> {
        self.restore(&mut i);
        mut_visit::noop_flat_map_impl_item(i, self)
    }

    fn flat_map_trait_item(&mut self, mut i: TraitItem) -> SmallVec<[TraitItem; 1]> {
        self.restore(&mut i);
        mut_visit::noop_flat_map_trait_item(i, self)
    }

    fn flat_map_foreign_item(&mut self, mut i: ForeignItem) -> SmallVec<[ForeignItem; 1]> {
        self.restore(&mut i);
        mut_visit::noop_flat_map_foreign_item(i, self)
    }

    fn flat_map_stmt(&mut self, mut s: Stmt) -> SmallVec<[Stmt; 1]> {
        self.restore(&mut s);
        mut_visit::noop_flat_map_stmt(s, self)
    }

    fn visit_expr(&mut self, e: &mut P<Expr>) {
        self.restore(e);
        mut_visit::noop_visit_expr(e, self)
    }

    fn visit_mac(&mut self, mac: &mut Mac) {
        mut_visit::noop_visit_mac(mac, self)
    }

    // TODO: extend this impl with the remaining node types
}

pub fn restore_cfg_attrs(krate: &mut Crate, node_attrs: HashMap<NodeId, Vec<Attribute>>) {
    let mut f = RestoreCfgAttrs { node_attrs };
    krate.visit(&mut f)
}

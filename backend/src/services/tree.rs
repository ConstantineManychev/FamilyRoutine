use std::collections::{HashMap, HashSet, VecDeque};

use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TreeError
{
    UnknownNode,
    Cycle,
    TooDeep,
}

#[derive(Debug, Default)]
pub struct Forest
{
    parents: HashMap<Uuid, Option<Uuid>>,
    children: HashMap<Uuid, Vec<Uuid>>,
}

impl Forest
{
    pub fn new(a_nodes: impl IntoIterator<Item = (Uuid, Option<Uuid>)>) -> Self
    {
        let mut forest = Self::default();
        for (id, parent) in a_nodes
        {
            forest.parents.insert(id, parent);
            if let Some(parent) = parent
            {
                forest.children.entry(parent).or_default().push(id);
            }
        }
        forest
    }

    pub fn contains(&self, a_id: Uuid) -> bool
    {
        self.parents.contains_key(&a_id)
    }

    pub fn parent(&self, a_id: Uuid) -> Option<Uuid>
    {
        self.parents.get(&a_id).copied().flatten()
    }

    pub fn children(&self, a_id: Uuid) -> &[Uuid]
    {
        self.children.get(&a_id).map(Vec::as_slice).unwrap_or_default()
    }

    pub fn ancestors(&self, a_id: Uuid) -> Vec<Uuid>
    {
        let mut path = Vec::new();
        let mut seen = HashSet::from([a_id]);
        let mut current = self.parent(a_id);
        while let Some(id) = current
        {
            if !seen.insert(id)
            {
                break;
            }
            path.push(id);
            current = self.parent(id);
        }
        path
    }

    pub fn depth(&self, a_id: Uuid) -> usize
    {
        self.ancestors(a_id).len() + 1
    }

    pub fn subtree(&self, a_id: Uuid) -> Vec<Uuid>
    {
        let mut ids = Vec::new();
        let mut seen = HashSet::new();
        let mut queue = VecDeque::from([a_id]);
        while let Some(id) = queue.pop_front()
        {
            if !seen.insert(id)
            {
                continue;
            }
            ids.push(id);
            queue.extend(self.children(id).iter().copied());
        }
        ids
    }

    pub fn height(&self, a_id: Uuid) -> usize
    {
        let base = self.depth(a_id);
        self.subtree(a_id)
            .into_iter()
            .map(|id| self.depth(id) - base + 1)
            .max()
            .unwrap_or(1)
    }

    pub fn is_within(&self, a_id: Uuid, a_root: Uuid) -> bool
    {
        a_id == a_root || self.ancestors(a_id).contains(&a_root)
    }

    fn depth_below(&self, a_parent: Option<Uuid>) -> Result<usize, TreeError>
    {
        match a_parent
        {
            None => Ok(0),
            Some(parent) if self.contains(parent) => Ok(self.depth(parent)),
            Some(_) => Err(TreeError::UnknownNode),
        }
    }

    pub fn check_add(&self, a_parent: Option<Uuid>, a_max_depth: usize) -> Result<(), TreeError>
    {
        if self.depth_below(a_parent)? + 1 > a_max_depth
        {
            return Err(TreeError::TooDeep);
        }
        Ok(())
    }

    pub fn check_move(&self, a_id: Uuid, a_parent: Option<Uuid>, a_max_depth: usize) -> Result<(), TreeError>
    {
        if !self.contains(a_id)
        {
            return Err(TreeError::UnknownNode);
        }
        if a_parent.is_some_and(|parent| self.is_within(parent, a_id))
        {
            return Err(TreeError::Cycle);
        }
        if self.parent(a_id) == a_parent
        {
            return Ok(());
        }
        if self.depth_below(a_parent)? + self.height(a_id) > a_max_depth
        {
            return Err(TreeError::TooDeep);
        }
        Ok(())
    }

    pub fn check_merge(&self, a_source: Uuid, a_target: Uuid, a_max_depth: usize) -> Result<(), TreeError>
    {
        if !self.contains(a_source) || !self.contains(a_target)
        {
            return Err(TreeError::UnknownNode);
        }
        if self.is_within(a_target, a_source)
        {
            return Err(TreeError::Cycle);
        }
        let moved_height = self.height(a_source) - 1;
        if moved_height > 0 && self.depth(a_target) + moved_height > a_max_depth
        {
            return Err(TreeError::TooDeep);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests
{
    use super::*;

    fn id(a_value: u128) -> Uuid
    {
        Uuid::from_u128(a_value)
    }

    fn sample() -> Forest
    {
        Forest::new([
            (id(1), None),
            (id(2), Some(id(1))),
            (id(3), Some(id(2))),
            (id(4), Some(id(1))),
            (id(5), None),
            (id(6), Some(id(5))),
        ])
    }

    #[test]
    fn depth_height_and_subtree_follow_the_parents()
    {
        let forest = sample();
        assert_eq!(forest.depth(id(1)), 1);
        assert_eq!(forest.depth(id(3)), 3);
        assert_eq!(forest.height(id(1)), 3);
        assert_eq!(forest.height(id(3)), 1);
        assert_eq!(forest.ancestors(id(3)), vec![id(2), id(1)]);
        let mut subtree = forest.subtree(id(1));
        subtree.sort();
        assert_eq!(subtree, vec![id(1), id(2), id(3), id(4)]);
        assert!(forest.is_within(id(3), id(1)));
        assert!(!forest.is_within(id(5), id(1)));
    }

    #[test]
    fn adding_respects_the_depth_limit()
    {
        let forest = sample();
        assert_eq!(forest.check_add(None, 3), Ok(()));
        assert_eq!(forest.check_add(Some(id(2)), 3), Ok(()));
        assert_eq!(forest.check_add(Some(id(3)), 3), Err(TreeError::TooDeep));
        assert_eq!(forest.check_add(Some(id(9)), 3), Err(TreeError::UnknownNode));
    }

    #[test]
    fn moves_reject_cycles_and_deep_branches()
    {
        let forest = sample();
        assert_eq!(forest.check_move(id(1), Some(id(3)), 5), Err(TreeError::Cycle));
        assert_eq!(forest.check_move(id(2), Some(id(2)), 5), Err(TreeError::Cycle));
        assert_eq!(forest.check_move(id(2), Some(id(5)), 3), Ok(()));
        assert_eq!(forest.check_move(id(2), Some(id(4)), 3), Err(TreeError::TooDeep));
        assert_eq!(forest.check_move(id(3), None, 3), Ok(()));
    }

    #[test]
    fn existing_deep_branches_keep_working_after_the_limit_drops()
    {
        let forest = sample();
        assert_eq!(forest.check_move(id(3), Some(id(2)), 2), Ok(()));
        assert_eq!(forest.check_add(Some(id(2)), 2), Err(TreeError::TooDeep));
    }

    #[test]
    fn merges_reject_targets_inside_the_source()
    {
        let forest = sample();
        assert_eq!(forest.check_merge(id(1), id(3), 5), Err(TreeError::Cycle));
        assert_eq!(forest.check_merge(id(2), id(4), 3), Ok(()));
        assert_eq!(forest.check_merge(id(1), id(5), 3), Ok(()));
        assert_eq!(forest.check_merge(id(1), id(6), 3), Err(TreeError::TooDeep));
        assert_eq!(forest.check_merge(id(4), id(6), 2), Ok(()));
    }
}

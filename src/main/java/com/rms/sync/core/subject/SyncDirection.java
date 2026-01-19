package com.rms.sync.core.subject;

/**
 * Message direction in the hierarchical topology.
 *
 * up   : child -> parent (Leaf -> Subzone -> Zone -> Central)
 * down : parent -> child (Central -> Zone -> Subzone -> Leaf)
 */
public enum SyncDirection {
    up, down
}

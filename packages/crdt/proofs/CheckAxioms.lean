import CrdtProofs

-- Option Id structural equality (1 B)
#print axioms CrdtProofs.opt_id_eq_iff

-- Full-domain UInt64 saturating & DeleteItem wraparound-free invariants (6 A)
#print axioms CrdtProofs.u64_sat_add_spec
#print axioms CrdtProofs.item_last_id_full_domain
#print axioms CrdtProofs.delete_item_contains_full_domain
#print axioms CrdtProofs.delete_item_can_merge_full_domain
#print axioms CrdtProofs.delete_item_merge_full_domain
#print axioms CrdtProofs.delete_item_merge_covers_both_full

-- Yjs v1 wire info byte & lib0 hex nibble invariants (4 B)
#print axioms CrdtProofs.encode_item_info_ref_id
#print axioms CrdtProofs.encode_item_info_bounds
#print axioms CrdtProofs.hex_nibble_roundtrip
#print axioms CrdtProofs.parse_hex_nibble_range

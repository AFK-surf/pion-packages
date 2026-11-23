// Unknown builtin value names are an error.
@compute @workgroup_size(1) fn cs_main(@builtin(thread_id) t : u32) { }

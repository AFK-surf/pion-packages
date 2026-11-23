| family | vectors | Pion spec-conform | Go paho (v5) | Rust rumqttc |
| --- | ---: | --- | --- | --- |
| A.fixed_header | 512 | 508/508 | 39/254 | 131/508 |
| B.vbi | 28 | 16/16 | 7/8 | 16/16 |
| B.rem_mismatch | 74 | 74/74 | 16/37 | 34/74 |
| B.truncated | 24 | 24/24 | 12/12 | 24/24 |
| C.utf8.topic | 396 | 260/260 | 101/130 | 228/260 |
| C.utf8.client_id | 396 | 260/260 | 103/130 | 258/260 |
| C.utf8.filter | 396 | 260/260 | 101/130 | 254/260 |
| C.utf8.len | 6 | 6/6 | 2/3 | 6/6 |
| C.utf8.user_prop | 198 | 130/130 | 103/130 | 129/130 |
| C.utf8.reason_string | 198 | 130/130 | 103/130 | 129/130 |
| D.prop_unknown | 294 | 294/294 | 294/294 | 294/294 |
| D.prop_allowed | 378 | 378/378 | 364/378 | 374/378 |
| D.prop_duplicate | 64 | 64/64 | 15/64 | 17/64 |
| D.prop_byte_value | 2048 | 2048/2048 | 16/2048 | 16/2048 |
| D.prop_u16_value | 7 | 7/7 | 4/7 | 4/7 |
| D.prop_u32_value | 2 | 2/2 | 0/2 | 0/2 |
| D.prop_subid | 6 | 6/6 | 4/6 | 4/6 |
| D.prop_len | 6 | 3/3 | 0/3 | 3/3 |
| D.prop_semantic | 2 | 1/2 | 1/2 | 1/2 |
| E.reason_code | 2304 | 95/95 (strict-acc 2209) | 95/95 (strict-acc 2209) | 63/95 |
| E.return_code | 512 | 262/262 (strict-acc 250) | n/a | 262/262 |
| E.connack_flags | 514 | 512/512 (strict-acc 2) | 2/256 (strict-acc 1) | 4/512 (strict-acc 2) |
| E.short_form | 26 | 26/26 | 17/22 | 13/26 |
| F.connect_flags | 512 | 512/512 | 56/256 | 386/512 |
| F.connect_proto | 36 | 34/34 | 1/17 | 33/34 |
| F.connect_cid | 4 | 2/2 | 1/1 | 2/2 |
| F.connect_will_topic | 8 | 8/8 | 1/4 | 2/8 |
| F.connect_trailing | 4 | 4/4 | 0/2 | 2/4 |
| G.filter | 124 | 116/124 | 32/62 | 72/124 |
| G.sub_options | 512 | 512/512 | 36/256 | 215/512 |
| G.empty | 8 | 7/7 | 0/3 (strict-acc 1) | 5/7 |
| G.pid0 | 6 | 6/6 | 0/3 | 2/6 |
| G.missing_opts | 2 | 2/2 | 0/1 | 2/2 |
| G.many | 2 | 2/2 | 1/1 | 2/2 |
| G.shared_nolocal | 2 | 1/2 | 1/2 | 1/2 |
| H.topic_name | 16 | 16/16 | 3/8 | 6/16 |
| H.topic_alias | 2 | 2/2 | 1/2 | 1/2 |
| H.pfi | 1 | - | - | - |
| I.mutation | 2500 | - | - | - |
| **total** | 12130 | 6590/6600 (strict-acc 2461) | 1532/4759 (strict-acc 2211) | 2995/6600 (strict-acc 2) |

pion_spec_violations=10 pion_strict_accepts=2461 three_way_disagreements=8143

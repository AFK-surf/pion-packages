import Aeneas
import PionLean
import Asn1.Types
import Asn1.Funs

open Aeneas Aeneas.Std Result Pion asn1

namespace Asn1Proofs

/-- Theorem 22: RFC 5280 §4.2.1.3 empty `KeyUsage` (`0`) has all 9 usage bits false. -/
theorem key_usage_zero_all_false :
    let ku := KeyUsage.mk 0#i32
    ku.digital_signature = ok false ∧
    ku.content_commitment = ok false ∧
    ku.key_encipherment = ok false ∧
    ku.data_encipherment = ok false ∧
    ku.key_agreement = ok false ∧
    ku.key_cert_sign = ok false ∧
    ku.crl_sign = ok false ∧
    ku.encipher_only = ok false ∧
    ku.decipher_only = ok false := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
    (dsimp only [KeyUsage.digital_signature, KeyUsage.content_commitment, KeyUsage.key_encipherment,
                 KeyUsage.data_encipherment, KeyUsage.key_agreement, KeyUsage.key_cert_sign,
                 KeyUsage.crl_sign, KeyUsage.encipher_only, KeyUsage.decipher_only];
     congr 1)

/-- Theorem 23: RFC 5280 §4.2.1.3 full 9-bit `KeyUsage` (`511 = 0x1FF`) has all 9 usage bits true. -/
theorem key_usage_all_ones_all_true :
    let ku := KeyUsage.mk 511#i32
    ku.digital_signature = ok true ∧
    ku.content_commitment = ok true ∧
    ku.key_encipherment = ok true ∧
    ku.data_encipherment = ok true ∧
    ku.key_agreement = ok true ∧
    ku.key_cert_sign = ok true ∧
    ku.crl_sign = ok true ∧
    ku.encipher_only = ok true ∧
    ku.decipher_only = ok true := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
    (dsimp only [KeyUsage.digital_signature, KeyUsage.content_commitment, KeyUsage.key_encipherment,
                 KeyUsage.data_encipherment, KeyUsage.key_agreement, KeyUsage.key_cert_sign,
                 KeyUsage.crl_sign, KeyUsage.encipher_only, KeyUsage.decipher_only];
     congr 1)

/-- Theorem 24: RFC 5280 §4.2.1.3 `KeyUsage` 9-bit flags are pairwise orthogonal (each single power-of-two bit selects its own flag exclusively). -/
theorem key_usage_single_bit_orthogonality :
    ((KeyUsage.mk 1#i32).digital_signature = ok true ∧ (KeyUsage.mk 1#i32).key_cert_sign = ok false) ∧
    ((KeyUsage.mk 2#i32).content_commitment = ok true ∧ (KeyUsage.mk 2#i32).digital_signature = ok false) ∧
    ((KeyUsage.mk 4#i32).key_encipherment = ok true ∧ (KeyUsage.mk 4#i32).data_encipherment = ok false) ∧
    ((KeyUsage.mk 8#i32).data_encipherment = ok true ∧ (KeyUsage.mk 8#i32).key_encipherment = ok false) ∧
    ((KeyUsage.mk 16#i32).key_agreement = ok true ∧ (KeyUsage.mk 16#i32).encipher_only = ok false) ∧
    ((KeyUsage.mk 32#i32).key_cert_sign = ok true ∧ (KeyUsage.mk 32#i32).crl_sign = ok false) ∧
    ((KeyUsage.mk 64#i32).crl_sign = ok true ∧ (KeyUsage.mk 64#i32).key_cert_sign = ok false) ∧
    ((KeyUsage.mk 128#i32).encipher_only = ok true ∧ (KeyUsage.mk 128#i32).decipher_only = ok false) ∧
    ((KeyUsage.mk 256#i32).decipher_only = ok true ∧ (KeyUsage.mk 256#i32).encipher_only = ok false) := by
  refine ⟨⟨?_, ?_⟩, ⟨?_, ?_⟩, ⟨?_, ?_⟩, ⟨?_, ?_⟩, ⟨?_, ?_⟩, ⟨?_, ?_⟩, ⟨?_, ?_⟩, ⟨?_, ?_⟩, ⟨?_, ?_⟩⟩ <;>
    (dsimp only [KeyUsage.digital_signature, KeyUsage.content_commitment, KeyUsage.key_encipherment,
                 KeyUsage.data_encipherment, KeyUsage.key_agreement, KeyUsage.key_cert_sign,
                 KeyUsage.crl_sign, KeyUsage.encipher_only, KeyUsage.decipher_only];
     congr 1)

end Asn1Proofs

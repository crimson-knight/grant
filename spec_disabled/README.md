# spec_disabled

Spec files here were moved from spec/ because they could not compile without
substantial API redesign. They are preserved for future reference.

## encryption_integration_spec.cr

Moved from `spec/grant/encryption_integration_spec.cr`.

Reasons:
1. Defines `class SecureUser < Grant::Base` which duplicates the `SecureUser`
   class already defined in `spec/grant/secure_features_integration_spec.cr`
   (both map to the `secure_users` table with incompatible schemas).
2. Uses `primary id : Int64, auto: true` — not valid Grant syntax; correct form
   is `column id : Int64, primary: true`.
3. Expects `Bytes?` from the encrypted column in raw queries, but
   `Grant::Encryption` stores encrypted data as Base64-encoded `String?`.
4. Calls `SecureUser.adapter` (undefined) and constructs raw DB queries that
   do not match the `Grant::Encryption` storage format.

To re-enable: rename the model, fix the primary-key declaration, and update
the raw query assertions to match the actual encrypted string storage format.

# Encrypted Attributes Implementation Plan

## Summary

Based on research and design analysis, here's the implementation plan for encrypted attributes in Grant:

## Key Technical Decisions

1. **Encryption Algorithm**: AES-256-GCM (authenticated encryption)
   - Provides both confidentiality and integrity
   - Built-in support via Crystal's OpenSSL bindings
   - Industry standard for secure encryption

2. **Key Management**: HKDF-based key derivation
   - Master key stored in environment variable
   - Derive unique keys per model/attribute
   - Support for deterministic encryption with separate key

3. **Storage Format**: Binary format with metadata header
   - 1-byte header for version and flags
   - 12-byte nonce/IV for non-deterministic
   - Variable-length ciphertext
   - 16-byte authentication tag

4. **Database Storage**: 
   - Add `_encrypted` BLOB/BYTEA columns for encrypted data
   - Original columns become virtual accessors
   - Transparent to application code

## Implementation Order

### Phase 1: Core Infrastructure (Days 1-2)
1. Create `Grant::Encryption` module structure
2. Implement `KeyProvider` class
   - Master key loading from ENV
   - HKDF key derivation
   - Key caching mechanism
3. Implement `Cipher` class
   - AES-256-GCM encryption/decryption
   - Binary format encoding/decoding
   - Error handling

### Phase 2: Model Integration (Days 3-4)
1. Create `EncryptedAttribute` class
   - Manages encryption lifecycle
   - Integrates with column system
2. Implement `encrypts` macro
   - Generates getter/setter methods
   - Creates encrypted column
   - Handles dirty tracking
3. Add configuration system
   - Global encryption settings
   - Per-attribute options

### Phase 3: Encryption Modes (Days 5-6)
1. Non-deterministic encryption (default)
   - Random IV generation
   - Different ciphertext each time
2. Deterministic encryption
   - Content-based IV derivation
   - Enables equality searches
   - Special security considerations

### Phase 4: Query Support (Day 7)
1. Deterministic field queries
   - Automatic encryption of query values
   - WHERE clause integration
2. Special query methods
   - `where_encrypted` for non-deterministic
   - Batch decryption optimization

### Phase 5: Migration & Tools (Days 8-9)
1. Migration helpers
   - Encrypt existing data
   - Progressive encryption support
   - Rollback capabilities
2. Key rotation tools
   - Re-encrypt with new keys
   - Zero-downtime rotation

### Phase 6: Testing & Documentation (Days 10-11)
1. Comprehensive test suite
   - Unit tests for each component
   - Integration tests with models
   - Security-focused tests
2. Documentation
   - Usage guide
   - Security best practices
   - Migration guide

## Technical Challenges & Solutions

### Challenge 1: Type System Integration
- **Problem**: Encrypted columns store binary data but appear as original type
- **Solution**: Virtual getters/setters with automatic conversion

### Challenge 2: Query Performance
- **Problem**: Can't use database indexes on encrypted data
- **Solution**: Deterministic encryption for searchable fields, partial indexes

### Challenge 3: Key Management
- **Problem**: Secure key storage and distribution
- **Solution**: Environment variables, support for external key providers

### Challenge 4: Migration Complexity
- **Problem**: Encrypting existing data without downtime
- **Solution**: Progressive encryption with dual-read support

## Security Considerations

1. **Key Storage**: Never commit keys to repository
2. **IV Generation**: Use `Random::Secure` for cryptographic randomness
3. **Authentication**: Use GCM mode for authenticated encryption
4. **Side Channels**: Consider timing attacks in equality comparisons
5. **Key Rotation**: Design for regular key rotation from day one

## Performance Optimizations

1. **Lazy Decryption**: Only decrypt when attribute is accessed
2. **Batch Operations**: Optimize for encrypting/decrypting multiple records
3. **Caching**: Cache decrypted values within request lifecycle
4. **Connection Pooling**: Reuse cipher contexts where safe

## Testing Strategy

### Unit Tests
- Cipher correctness
- Key derivation
- Binary format parsing
- Edge cases (nil, empty, large data)

### Integration Tests
- Model integration
- Dirty tracking
- Callbacks interaction
- Transaction handling

### Security Tests
- Verify no plaintext storage
- Test encryption strength
- Key rotation scenarios
- Error handling without info leakage

### Performance Tests
- Benchmark encryption overhead
- Query performance impact
- Memory usage with caching

## Success Criteria

1. ✅ Transparent encryption/decryption
2. ✅ Rails-compatible API
3. ✅ Support for deterministic encryption
4. ✅ Database-agnostic implementation
5. ✅ Comprehensive test coverage
6. ✅ Security best practices followed
7. ✅ Performance overhead < 10% for typical usage
8. ✅ Clear migration path for existing apps

## Next Steps

1. Review plan with team
2. Set up development environment
3. Begin Phase 1 implementation
4. Create proof-of-concept for core encryption

This plan provides a structured approach to implementing encrypted attributes while maintaining security, performance, and usability.
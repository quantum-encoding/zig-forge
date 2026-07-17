/**
 * Token Service - WebAssembly Auth Module
 *
 * High-performance authentication powered by Zig + WASM.
 * Features: JWT signing/verification, UUID generation, Base58 encoding.
 *
 * ---------------------------------------------------------------------------
 * SECURITY / TRUST MODEL (read before shipping)
 * ---------------------------------------------------------------------------
 * This module holds the HMAC signing secret in browser memory (`init()` copies
 * it into the WASM instance) and reads the wall clock from JavaScript
 * (`js_get_timestamp`) for expiry checks. Therefore:
 *
 *   - Anyone with access to the page can extract the secret and forge tokens.
 *   - A client can move its own clock to bypass `exp`.
 *   - `verifyToken()` here is algorithm-blind: it recomputes HMAC-SHA256 over
 *     `header.payload` and compares. It is safe against `alg:none` / alg
 *     confusion (a forged token fails the HMAC), but it does not parse or
 *     enforce the header `alg`/`typ`.
 *
 * This is a UX / offline convenience, NOT a security boundary. Tokens minted or
 * accepted here MUST be re-verified server-side with the secret held privately.
 * Do not ship this as the sole verifier.
 *
 * ---------------------------------------------------------------------------
 * WASM ABI (matches src/wasm_ffi.zig — no alloc/free; fixed staging buffers)
 * ---------------------------------------------------------------------------
 * Staging:   get_input_ptr() -> ptr, get_input_size() -> max bytes
 * Result:    get_result_ptr() -> ptr, get_result_len() -> byte length
 * Errors:    get_error_code() -> i32 (0 ok, negative on failure)
 * Ops:       init(ptr,len) -> i32(0 ok)
 *            sign_token(ptr,len,expiresIn) -> u32 token length (0 on failure)
 *            verify_token(ptr,len) -> i32 (1 valid, 0 invalid)
 *            uuid_v4() / uuid_v7() -> u32 length (result in result buffer)
 *            base58_encode(ptr,len) / base58_decode(ptr,len) -> u32 length
 *            get_version_major/minor/patch() -> u32
 * Imports:   env.js_get_timestamp() -> i32 seconds
 *            env.js_get_random_bytes(ptr,len) -> void
 *
 * Usage:
 * ```javascript
 * import { TokenService } from './token-service.js';
 *
 * const auth = await TokenService.create('your-secret-key');
 *
 * const token = auth.signToken('user123', 3600);
 * const { valid, userId } = auth.verifyToken(token);
 * const id = auth.uuid();
 * const sortableId = auth.uuidV7();
 * ```
 */

const ERROR_MESSAGES = {
    [-1]: 'Not initialized',
    [-2]: 'Invalid input',
    [-3]: 'Sign failed',
    [-4]: 'Invalid signature',
    [-5]: 'Token expired',
    [-7]: 'Buffer too small',
};

export class TokenService {
    constructor(exports) {
        this.wasm = exports;
        this.memory = exports.memory;
        this.encoder = new TextEncoder();
        this.decoder = new TextDecoder();
    }

    /**
     * Build the import object the WASM module requires. Both imports are
     * mandatory — omitting `js_get_random_bytes` makes instantiation throw.
     */
    static _imports(getMemory) {
        return {
            env: {
                js_get_timestamp: () => Math.floor(Date.now() / 1000),
                js_get_random_bytes: (ptr, len) => {
                    const bytes = new Uint8Array(getMemory().buffer, ptr, len);
                    crypto.getRandomValues(bytes);
                },
            },
        };
    }

    /**
     * Create a new TokenService instance by fetching a .wasm URL.
     * @param {string} secret - Secret key for JWT signing
     * @param {string} wasmPath - Path to the WASM file
     */
    static async create(secret, wasmPath = 'token_service.wasm') {
        // memory is only available after instantiation; the import closures
        // read it lazily so they see the instance's exported memory.
        let memoryRef = null;
        const imports = TokenService._imports(() => memoryRef);

        const response = await fetch(wasmPath);
        if (!response.ok) {
            throw new Error(`Failed to fetch WASM (${response.status}) from ${wasmPath}`);
        }
        const { instance } = await WebAssembly.instantiateStreaming(response, imports);
        memoryRef = instance.exports.memory;

        const service = new TokenService(instance.exports);
        service.init(secret);
        return service;
    }

    /**
     * Create from an ArrayBuffer (for bundlers / offline).
     */
    static async createFromBuffer(buffer, secret) {
        let memoryRef = null;
        const imports = TokenService._imports(() => memoryRef);

        const { instance } = await WebAssembly.instantiate(buffer, imports);
        memoryRef = instance.exports.memory;

        const service = new TokenService(instance.exports);
        service.init(secret);
        return service;
    }

    /**
     * Initialize with a secret key. Throws on failure.
     */
    init(secret) {
        const { len } = this._writeInput(this.encoder.encode(secret));
        const result = this.wasm.init(this.wasm.get_input_ptr(), len);
        if (result !== 0) {
            throw new Error(`Failed to initialize: ${this._errorText(result)}`);
        }
    }

    /**
     * Sign a JWT token.
     * @param {string} userId - User identifier (subject claim)
     * @param {number} expiresIn - Expiration time in seconds (default: 3600)
     * @returns {string} JWT token
     */
    signToken(userId, expiresIn = 3600) {
        const { len } = this._writeInput(this.encoder.encode(userId));
        const tokenLen = this.wasm.sign_token(this.wasm.get_input_ptr(), len, expiresIn);
        if (tokenLen === 0) {
            throw new Error(`Sign failed: ${this._errorText(this.wasm.get_error_code())}`);
        }
        return this._readResultText();
    }

    /**
     * Verify a JWT token.
     * @param {string} token - JWT token to verify
     * @returns {{ valid: boolean, userId: string | null, error?: string }}
     */
    verifyToken(token) {
        const { len } = this._writeInput(this.encoder.encode(token));
        const valid = this.wasm.verify_token(this.wasm.get_input_ptr(), len);
        if (valid === 1) {
            return { valid: true, userId: this._readResultText() };
        }
        return {
            valid: false,
            userId: null,
            error: this._errorText(this.wasm.get_error_code()),
        };
    }

    /**
     * Generate a UUID v4 (random).
     * @returns {string} UUID string
     */
    uuid() {
        const len = this.wasm.uuid_v4();
        if (len === 0) {
            throw new Error(`UUID generation failed: ${this._errorText(this.wasm.get_error_code())}`);
        }
        return this._readResultText();
    }

    /**
     * Generate a UUID v7 (time-sortable).
     * @returns {string} UUID string
     */
    uuidV7() {
        const len = this.wasm.uuid_v7();
        if (len === 0) {
            throw new Error(`UUID generation failed: ${this._errorText(this.wasm.get_error_code())}`);
        }
        return this._readResultText();
    }

    /**
     * Encode data as Base58.
     * @param {string | Uint8Array} data - Data to encode
     * @returns {string} Base58 encoded string
     */
    base58Encode(data) {
        const bytes = typeof data === 'string' ? this.encoder.encode(data) : data;
        const { len } = this._writeInput(bytes);
        const resultLen = this.wasm.base58_encode(this.wasm.get_input_ptr(), len);
        if (resultLen === 0) {
            throw new Error(`Base58 encoding failed: ${this._errorText(this.wasm.get_error_code())}`);
        }
        return this._readResultText();
    }

    /**
     * Decode a Base58 string.
     * @param {string} encoded - Base58 encoded string
     * @returns {Uint8Array} Decoded bytes (a copy — safe across later calls)
     */
    base58Decode(encoded) {
        const { len } = this._writeInput(this.encoder.encode(encoded));
        const resultLen = this.wasm.base58_decode(this.wasm.get_input_ptr(), len);
        if (resultLen === 0) {
            throw new Error(`Base58 decoding failed: ${this._errorText(this.wasm.get_error_code())}`);
        }
        return this._readResultBytes();
    }

    /**
     * Get version info.
     */
    get version() {
        const major = this.wasm.get_version_major();
        const minor = this.wasm.get_version_minor();
        const patch = this.wasm.get_version_patch();
        return { major, minor, patch, string: `${major}.${minor}.${patch}` };
    }

    // ----------------------------------------------------------------------
    // Internal helpers
    // ----------------------------------------------------------------------

    /**
     * Stage bytes into the WASM input buffer (get_input_ptr / get_input_size).
     * There is no alloc/free in this ABI — the buffer is a fixed global.
     */
    _writeInput(bytes) {
        const ptr = this.wasm.get_input_ptr();
        const max = this.wasm.get_input_size();
        if (bytes.length > max) {
            throw new Error(`Input too large: ${bytes.length} > ${max} bytes`);
        }
        new Uint8Array(this.memory.buffer, ptr, bytes.length).set(bytes);
        return { ptr, len: bytes.length };
    }

    /** Read the current result buffer as a decoded UTF-8 string. */
    _readResultText() {
        const ptr = this.wasm.get_result_ptr();
        const len = this.wasm.get_result_len();
        return this.decoder.decode(new Uint8Array(this.memory.buffer, ptr, len));
    }

    /** Read the current result buffer as a copy of the raw bytes. */
    _readResultBytes() {
        const ptr = this.wasm.get_result_ptr();
        const len = this.wasm.get_result_len();
        // .slice() copies out of the WASM heap so the caller keeps valid data
        // even after the next WASM call reuses the buffer or memory grows.
        return new Uint8Array(this.memory.buffer, ptr, len).slice();
    }

    _errorText(code) {
        return ERROR_MESSAGES[code] || `Error code ${code}`;
    }
}

// UMD-style export for non-module usage.
if (typeof window !== 'undefined') {
    window.TokenService = TokenService;
}

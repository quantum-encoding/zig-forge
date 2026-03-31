//! Secret Detection Patterns
//!
//! Defines regex-like patterns for detecting secrets, API keys, tokens, and credentials.
//! Patterns are organized by provider/type for easy configuration.

const std = @import("std");

/// Severity level for findings
pub const Severity = enum {
    critical, // Private keys, database passwords
    high, // API keys with full access
    medium, // Tokens with limited scope
    low, // Potentially sensitive (may be false positive)
    info, // Informational only

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .critical => "CRITICAL",
            .high => "HIGH",
            .medium => "MEDIUM",
            .low => "LOW",
            .info => "INFO",
        };
    }

    pub fn toColor(self: Severity) []const u8 {
        return switch (self) {
            .critical => "\x1b[91m", // Bright red
            .high => "\x1b[31m", // Red
            .medium => "\x1b[33m", // Yellow
            .low => "\x1b[36m", // Cyan
            .info => "\x1b[37m", // White
        };
    }
};

/// A pattern definition for secret detection
pub const Pattern = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    severity: Severity,
    pattern_type: PatternType,
    // For prefix patterns
    prefix: ?[]const u8 = null,
    prefix_len: ?usize = null,
    // For keyword patterns
    keywords: ?[]const []const u8 = null,
    // Minimum entropy threshold (0.0-1.0, null = no entropy check)
    min_entropy: ?f32 = null,
    // Expected length range
    min_length: usize = 0,
    max_length: usize = 1024,
    // Character set for validation
    charset: ?Charset = null,
    // Should be enabled by default
    enabled: bool = true,
};

pub const PatternType = enum {
    prefix, // Matches strings starting with a prefix
    keyword, // Matches lines containing keywords
    regex_like, // Matches a regex-like pattern
    entropy, // High-entropy string detection
    pem_block, // PEM-encoded keys/certificates
};

pub const Charset = enum {
    alphanumeric, // a-zA-Z0-9
    alphanumeric_plus, // a-zA-Z0-9+/=
    hex, // a-fA-F0-9
    base64, // a-zA-Z0-9+/=
    base64url, // a-zA-Z0-9-_

    pub fn isValid(self: Charset, c: u8) bool {
        return switch (self) {
            .alphanumeric => std.ascii.isAlphanumeric(c),
            .alphanumeric_plus => std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=',
            .hex => std.ascii.isHex(c),
            .base64 => std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=',
            .base64url => std.ascii.isAlphanumeric(c) or c == '-' or c == '_',
        };
    }
};

// =============================================================================
// Built-in Pattern Definitions
// =============================================================================

/// AWS patterns
pub const aws_patterns = [_]Pattern{
    .{
        .id = "aws-access-key",
        .name = "AWS Access Key ID",
        .description = "AWS access key starting with AKIA, ABIA, ACCA, or ASIA",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "AKIA",
        .prefix_len = 4,
        .min_length = 20,
        .max_length = 20,
        .charset = .alphanumeric,
    },
    .{
        .id = "aws-secret-key",
        .name = "AWS Secret Access Key",
        .description = "40-character AWS secret key",
        .severity = .critical,
        .pattern_type = .keyword,
        .keywords = &.{ "aws_secret_access_key", "AWS_SECRET_ACCESS_KEY", "aws_secret_key" },
        .min_length = 40,
        .max_length = 40,
        .charset = .alphanumeric_plus,
    },
    .{
        .id = "aws-session-token",
        .name = "AWS Session Token",
        .description = "AWS temporary session token",
        .severity = .high,
        .pattern_type = .keyword,
        .keywords = &.{ "aws_session_token", "AWS_SESSION_TOKEN" },
        .min_length = 100,
        .max_length = 2000,
    },
};

/// GitHub patterns
pub const github_patterns = [_]Pattern{
    .{
        .id = "github-pat",
        .name = "GitHub Personal Access Token",
        .description = "GitHub PAT starting with ghp_",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "ghp_",
        .prefix_len = 4,
        .min_length = 40,
        .max_length = 255,
        .charset = .alphanumeric,
    },
    .{
        .id = "github-oauth",
        .name = "GitHub OAuth Access Token",
        .description = "GitHub OAuth token starting with gho_",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "gho_",
        .prefix_len = 4,
        .min_length = 40,
        .max_length = 255,
        .charset = .alphanumeric,
    },
    .{
        .id = "github-app-token",
        .name = "GitHub App Token",
        .description = "GitHub App installation token starting with ghs_",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "ghs_",
        .prefix_len = 4,
        .min_length = 40,
        .max_length = 255,
        .charset = .alphanumeric,
    },
    .{
        .id = "github-refresh-token",
        .name = "GitHub Refresh Token",
        .description = "GitHub refresh token starting with ghr_",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "ghr_",
        .prefix_len = 4,
        .min_length = 40,
        .max_length = 255,
        .charset = .alphanumeric,
    },
    .{
        .id = "github-fine-grained",
        .name = "GitHub Fine-Grained PAT",
        .description = "GitHub fine-grained PAT starting with github_pat_",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "github_pat_",
        .prefix_len = 11,
        .min_length = 80,
        .max_length = 255,
    },
};

/// GitLab patterns
pub const gitlab_patterns = [_]Pattern{
    .{
        .id = "gitlab-pat",
        .name = "GitLab Personal Access Token",
        .description = "GitLab PAT starting with glpat-",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "glpat-",
        .prefix_len = 6,
        .min_length = 26,
        .max_length = 30,
    },
    .{
        .id = "gitlab-pipeline",
        .name = "GitLab Pipeline Token",
        .description = "GitLab CI/CD pipeline token",
        .severity = .medium,
        .pattern_type = .prefix,
        .prefix = "glcbt-",
        .prefix_len = 6,
        .min_length = 26,
        .max_length = 64,
    },
    .{
        .id = "gitlab-runner",
        .name = "GitLab Runner Token",
        .description = "GitLab Runner registration token",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "glrt-",
        .prefix_len = 5,
        .min_length = 26,
        .max_length = 64,
    },
};

/// Slack patterns
pub const slack_patterns = [_]Pattern{
    .{
        .id = "slack-bot-token",
        .name = "Slack Bot Token",
        .description = "Slack bot user OAuth token",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "xoxb-",
        .prefix_len = 5,
        .min_length = 50,
        .max_length = 255,
    },
    .{
        .id = "slack-user-token",
        .name = "Slack User Token",
        .description = "Slack user OAuth token",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "xoxp-",
        .prefix_len = 5,
        .min_length = 50,
        .max_length = 255,
    },
    .{
        .id = "slack-app-token",
        .name = "Slack App Token",
        .description = "Slack app-level token",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "xapp-",
        .prefix_len = 5,
        .min_length = 50,
        .max_length = 255,
    },
    .{
        .id = "slack-webhook",
        .name = "Slack Webhook URL",
        .description = "Slack incoming webhook URL",
        .severity = .medium,
        .pattern_type = .prefix,
        .prefix = "https://hooks.slack.com/",
        .prefix_len = 24,
        .min_length = 80,
        .max_length = 255,
    },
};

/// Stripe patterns
pub const stripe_patterns = [_]Pattern{
    .{
        .id = "stripe-live-secret",
        .name = "Stripe Live Secret Key",
        .description = "Stripe live mode secret key",
        .severity = .critical,
        .pattern_type = .prefix,
        .prefix = "sk_live_",
        .prefix_len = 8,
        .min_length = 32,
        .max_length = 255,
    },
    .{
        .id = "stripe-live-publishable",
        .name = "Stripe Live Publishable Key",
        .description = "Stripe live mode publishable key",
        .severity = .low,
        .pattern_type = .prefix,
        .prefix = "pk_live_",
        .prefix_len = 8,
        .min_length = 32,
        .max_length = 255,
    },
    .{
        .id = "stripe-test-secret",
        .name = "Stripe Test Secret Key",
        .description = "Stripe test mode secret key",
        .severity = .low,
        .pattern_type = .prefix,
        .prefix = "sk_test_",
        .prefix_len = 8,
        .min_length = 32,
        .max_length = 255,
        .enabled = false, // Disabled by default (test keys)
    },
    .{
        .id = "stripe-restricted",
        .name = "Stripe Restricted Key",
        .description = "Stripe restricted API key",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "rk_live_",
        .prefix_len = 8,
        .min_length = 32,
        .max_length = 255,
    },
};

/// Google/GCP patterns
pub const google_patterns = [_]Pattern{
    .{
        .id = "google-api-key",
        .name = "Google API Key",
        .description = "Google Cloud API key starting with AIza",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "AIza",
        .prefix_len = 4,
        .min_length = 39,
        .max_length = 39,
    },
    .{
        .id = "google-oauth-client-id",
        .name = "Google OAuth Client ID",
        .description = "Google OAuth 2.0 client ID",
        .severity = .medium,
        .pattern_type = .keyword,
        .keywords = &.{".apps.googleusercontent.com"},
        .min_length = 50,
        .max_length = 150,
    },
    .{
        .id = "gcp-service-account",
        .name = "GCP Service Account Key",
        .description = "Google Cloud service account private key",
        .severity = .critical,
        .pattern_type = .keyword,
        .keywords = &.{ "\"type\": \"service_account\"", "\"private_key\":" },
        .min_length = 100,
        .max_length = 5000,
    },
};

/// OpenAI/AI Provider patterns
pub const ai_patterns = [_]Pattern{
    .{
        .id = "openai-api-key",
        .name = "OpenAI API Key",
        .description = "OpenAI API key starting with sk-",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "sk-",
        .prefix_len = 3,
        .min_length = 40,
        .max_length = 60,
        .charset = .alphanumeric,
    },
    .{
        .id = "anthropic-api-key",
        .name = "Anthropic API Key",
        .description = "Anthropic/Claude API key starting with sk-ant-",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "sk-ant-",
        .prefix_len = 7,
        .min_length = 90,
        .max_length = 120,
    },
    .{
        .id = "huggingface-token",
        .name = "Hugging Face Token",
        .description = "Hugging Face API token",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "hf_",
        .prefix_len = 3,
        .min_length = 30,
        .max_length = 50,
        .charset = .alphanumeric,
    },
};

/// Database patterns
pub const database_patterns = [_]Pattern{
    .{
        .id = "postgres-url",
        .name = "PostgreSQL Connection URL",
        .description = "PostgreSQL connection string with credentials",
        .severity = .critical,
        .pattern_type = .prefix,
        .prefix = "postgres://",
        .prefix_len = 11,
        .min_length = 20,
        .max_length = 500,
    },
    .{
        .id = "mysql-url",
        .name = "MySQL Connection URL",
        .description = "MySQL connection string with credentials",
        .severity = .critical,
        .pattern_type = .prefix,
        .prefix = "mysql://",
        .prefix_len = 8,
        .min_length = 20,
        .max_length = 500,
    },
    .{
        .id = "mongodb-url",
        .name = "MongoDB Connection URL",
        .description = "MongoDB connection string with credentials",
        .severity = .critical,
        .pattern_type = .prefix,
        .prefix = "mongodb://",
        .prefix_len = 10,
        .min_length = 20,
        .max_length = 500,
    },
    .{
        .id = "mongodb-srv-url",
        .name = "MongoDB SRV Connection URL",
        .description = "MongoDB SRV connection string with credentials",
        .severity = .critical,
        .pattern_type = .prefix,
        .prefix = "mongodb+srv://",
        .prefix_len = 14,
        .min_length = 20,
        .max_length = 500,
    },
    .{
        .id = "redis-url",
        .name = "Redis Connection URL",
        .description = "Redis connection string with credentials",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "redis://",
        .prefix_len = 8,
        .min_length = 15,
        .max_length = 500,
    },
};

/// Private key patterns
pub const key_patterns = [_]Pattern{
    .{
        .id = "rsa-private-key",
        .name = "RSA Private Key",
        .description = "RSA private key in PEM format",
        .severity = .critical,
        .pattern_type = .pem_block,
        .prefix = "-----BEGIN RSA PRIVATE KEY-----",
        .prefix_len = 31,
        .min_length = 100,
        .max_length = 10000,
    },
    .{
        .id = "openssh-private-key",
        .name = "OpenSSH Private Key",
        .description = "OpenSSH private key",
        .severity = .critical,
        .pattern_type = .pem_block,
        .prefix = "-----BEGIN OPENSSH PRIVATE KEY-----",
        .prefix_len = 35,
        .min_length = 100,
        .max_length = 10000,
    },
    .{
        .id = "ec-private-key",
        .name = "EC Private Key",
        .description = "Elliptic curve private key",
        .severity = .critical,
        .pattern_type = .pem_block,
        .prefix = "-----BEGIN EC PRIVATE KEY-----",
        .prefix_len = 30,
        .min_length = 100,
        .max_length = 5000,
    },
    .{
        .id = "dsa-private-key",
        .name = "DSA Private Key",
        .description = "DSA private key",
        .severity = .critical,
        .pattern_type = .pem_block,
        .prefix = "-----BEGIN DSA PRIVATE KEY-----",
        .prefix_len = 31,
        .min_length = 100,
        .max_length = 5000,
    },
    .{
        .id = "pgp-private-key",
        .name = "PGP Private Key",
        .description = "PGP/GPG private key block",
        .severity = .critical,
        .pattern_type = .pem_block,
        .prefix = "-----BEGIN PGP PRIVATE KEY BLOCK-----",
        .prefix_len = 37,
        .min_length = 100,
        .max_length = 20000,
    },
    .{
        .id = "encrypted-private-key",
        .name = "Encrypted Private Key",
        .description = "PKCS#8 encrypted private key",
        .severity = .high,
        .pattern_type = .pem_block,
        .prefix = "-----BEGIN ENCRYPTED PRIVATE KEY-----",
        .prefix_len = 37,
        .min_length = 100,
        .max_length = 10000,
    },
};

/// Generic patterns (keyword-based)
pub const generic_patterns = [_]Pattern{
    .{
        .id = "generic-api-key",
        .name = "Generic API Key",
        .description = "Generic API key assignment",
        .severity = .medium,
        .pattern_type = .keyword,
        .keywords = &.{ "api_key", "apikey", "API_KEY", "APIKEY", "api-key" },
        .min_entropy = 0.6,
        .min_length = 16,
        .max_length = 128,
    },
    .{
        .id = "generic-secret",
        .name = "Generic Secret",
        .description = "Generic secret assignment",
        .severity = .medium,
        .pattern_type = .keyword,
        .keywords = &.{ "secret", "SECRET", "password", "PASSWORD", "passwd", "PASSWD" },
        .min_entropy = 0.5,
        .min_length = 8,
        .max_length = 128,
    },
    .{
        .id = "generic-token",
        .name = "Generic Token",
        .description = "Generic token assignment",
        .severity = .medium,
        .pattern_type = .keyword,
        .keywords = &.{ "token", "TOKEN", "auth_token", "AUTH_TOKEN", "access_token", "ACCESS_TOKEN" },
        .min_entropy = 0.5,
        .min_length = 20,
        .max_length = 500,
    },
    .{
        .id = "bearer-token",
        .name = "Bearer Token",
        .description = "HTTP Bearer authentication token",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "Bearer ",
        .prefix_len = 7,
        .min_entropy = 0.5,
        .min_length = 20,
        .max_length = 2000,
    },
};

/// JWT patterns
pub const jwt_patterns = [_]Pattern{
    .{
        .id = "jwt-token",
        .name = "JSON Web Token",
        .description = "JWT with header.payload.signature format",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "eyJ",
        .prefix_len = 3,
        .min_length = 50,
        .max_length = 4000,
        .charset = .base64url,
    },
};

/// npm/package manager patterns
pub const package_patterns = [_]Pattern{
    .{
        .id = "npm-token",
        .name = "NPM Access Token",
        .description = "NPM registry access token",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "npm_",
        .prefix_len = 4,
        .min_length = 36,
        .max_length = 50,
    },
    .{
        .id = "pypi-token",
        .name = "PyPI API Token",
        .description = "Python Package Index API token",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "pypi-",
        .prefix_len = 5,
        .min_length = 50,
        .max_length = 200,
    },
};

/// Discord patterns
pub const discord_patterns = [_]Pattern{
    .{
        .id = "discord-bot-token",
        .name = "Discord Bot Token",
        .description = "Discord bot authentication token",
        .severity = .high,
        .pattern_type = .entropy,
        .min_entropy = 0.7,
        .min_length = 59,
        .max_length = 72,
        .charset = .base64,
    },
    .{
        .id = "discord-webhook",
        .name = "Discord Webhook URL",
        .description = "Discord webhook URL",
        .severity = .medium,
        .pattern_type = .prefix,
        .prefix = "https://discord.com/api/webhooks/",
        .prefix_len = 33,
        .min_length = 100,
        .max_length = 200,
    },
};

/// Twilio patterns
pub const twilio_patterns = [_]Pattern{
    .{
        .id = "twilio-account-sid",
        .name = "Twilio Account SID",
        .description = "Twilio account identifier",
        .severity = .medium,
        .pattern_type = .prefix,
        .prefix = "AC",
        .prefix_len = 2,
        .min_length = 34,
        .max_length = 34,
        .charset = .hex,
    },
    .{
        .id = "twilio-auth-token",
        .name = "Twilio Auth Token",
        .description = "Twilio authentication token",
        .severity = .high,
        .pattern_type = .keyword,
        .keywords = &.{ "TWILIO_AUTH_TOKEN", "twilio_auth_token" },
        .min_length = 32,
        .max_length = 32,
        .charset = .hex,
    },
};

/// SendGrid patterns
pub const sendgrid_patterns = [_]Pattern{
    .{
        .id = "sendgrid-api-key",
        .name = "SendGrid API Key",
        .description = "SendGrid mail API key",
        .severity = .high,
        .pattern_type = .prefix,
        .prefix = "SG.",
        .prefix_len = 3,
        .min_length = 50,
        .max_length = 100,
    },
};

/// Mailchimp patterns
pub const mailchimp_patterns = [_]Pattern{
    .{
        .id = "mailchimp-api-key",
        .name = "Mailchimp API Key",
        .description = "Mailchimp marketing API key",
        .severity = .high,
        .pattern_type = .keyword,
        .keywords = &.{"-us"},
        .min_length = 32,
        .max_length = 50,
        .charset = .hex,
    },
};

/// Azure patterns
pub const azure_patterns = [_]Pattern{
    .{
        .id = "azure-storage-key",
        .name = "Azure Storage Account Key",
        .description = "Azure storage account access key",
        .severity = .critical,
        .pattern_type = .keyword,
        .keywords = &.{ "AccountKey=", "SharedAccessSignature=" },
        .min_length = 80,
        .max_length = 200,
        .charset = .base64,
    },
    .{
        .id = "azure-connection-string",
        .name = "Azure Connection String",
        .description = "Azure service connection string",
        .severity = .critical,
        .pattern_type = .prefix,
        .prefix = "DefaultEndpointsProtocol=",
        .prefix_len = 25,
        .min_length = 100,
        .max_length = 500,
    },
};

// =============================================================================
// Pattern Registry
// =============================================================================

const total_pattern_count = aws_patterns.len + github_patterns.len + gitlab_patterns.len +
    slack_patterns.len + stripe_patterns.len + google_patterns.len +
    ai_patterns.len + database_patterns.len + key_patterns.len +
    generic_patterns.len + jwt_patterns.len + package_patterns.len +
    discord_patterns.len + twilio_patterns.len + sendgrid_patterns.len +
    mailchimp_patterns.len + azure_patterns.len;

const all_patterns: [total_pattern_count]Pattern = blk: {
    var all: [total_pattern_count]Pattern = undefined;
    var idx: usize = 0;

    for (aws_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (github_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (gitlab_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (slack_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (stripe_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (google_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (ai_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (database_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (key_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (generic_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (jwt_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (package_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (discord_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (twilio_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (sendgrid_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (mailchimp_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }
    for (azure_patterns) |p| {
        all[idx] = p;
        idx += 1;
    }

    break :blk all;
};

/// Get all built-in patterns
pub fn getAllPatterns() []const Pattern {
    return &all_patterns;
}

/// Get pattern by ID
pub fn getPatternById(id: []const u8) ?Pattern {
    for (getAllPatterns()) |p| {
        if (std.mem.eql(u8, p.id, id)) return p;
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "pattern counts" {
    const all = getAllPatterns();
    try std.testing.expect(all.len > 50);
}

test "get pattern by id" {
    const p = getPatternById("aws-access-key");
    try std.testing.expect(p != null);
    try std.testing.expectEqualStrings("AWS Access Key ID", p.?.name);
}

test "severity to string" {
    try std.testing.expectEqualStrings("CRITICAL", Severity.critical.toString());
    try std.testing.expectEqualStrings("HIGH", Severity.high.toString());
}

// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
// 
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");

/// HTTP client errors
pub const HttpError = error{
    // Network errors
    ConnectionRefused,
    ConnectionTimeout,
    ConnectionReset,
    NetworkUnreachable,
    HostUnreachable,
    DnsResolutionFailed,
    
    // HTTP errors
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    MethodNotAllowed,
    NotAcceptable,
    RequestTimeout,
    Conflict,
    Gone,
    UnprocessableEntity,
    TooManyRequests,
    InternalServerError,
    BadGateway,
    ServiceUnavailable,
    GatewayTimeout,
    
    // Client errors
    InvalidUrl,
    InvalidResponse,
    ResponseTooLarge,
    RequestCancelled,
    PoolExhausted,
    CircuitBreakerOpen,
    RateLimitExceeded,
};

/// Check if an error is retryable
pub fn isRetryable(err: HttpError) bool {
    return switch (err) {
        // Network errors - usually retryable
        error.ConnectionRefused,
        error.ConnectionTimeout,
        error.ConnectionReset,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.DnsResolutionFailed,
        
        // HTTP 5xx errors - server issues, retryable
        error.InternalServerError,
        error.BadGateway,
        error.ServiceUnavailable,
        error.GatewayTimeout,
        
        // Rate limiting - retryable with backoff
        error.TooManyRequests,
        error.RequestTimeout => true,
        
        // Everything else is not retryable
        else => false,
    };
}

/// Convert HTTP status code to error
pub fn fromStatusCode(status: std.http.Status) ?HttpError {
    return switch (status) {
        .bad_request => error.BadRequest,
        .unauthorized => error.Unauthorized,
        .forbidden => error.Forbidden,
        .not_found => error.NotFound,
        .method_not_allowed => error.MethodNotAllowed,
        .not_acceptable => error.NotAcceptable,
        .request_timeout => error.RequestTimeout,
        .conflict => error.Conflict,
        .gone => error.Gone,
        .unprocessable_entity => error.UnprocessableEntity,
        .too_many_requests => error.TooManyRequests,
        .internal_server_error => error.InternalServerError,
        .bad_gateway => error.BadGateway,
        .service_unavailable => error.ServiceUnavailable,
        .gateway_timeout => error.GatewayTimeout,
        else => null,
    };
}
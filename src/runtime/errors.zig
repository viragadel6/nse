const std = @import("std");

pub fn status(err: anyerror) std.http.Status {
    return switch (err) {
        error.DocumentNotFound => .not_found,
        error.QueueFull, error.IndexNotReady, error.EmbeddingServiceNotConfigured, error.EmbeddingServiceUnavailable, error.Cancelled => .service_unavailable,
        error.DeadlineExceeded => .gateway_timeout,
        error.OutOfMemory, error.NoSpaceLeft, error.InputOutput, error.AccessDenied => .internal_server_error,
        error.InvalidQuery, error.InvalidDeadline, error.InvalidFilter, error.InvalidEmbeddingDimensions, error.InvalidEmbeddingValue, error.ZeroEmbedding, error.InvalidDocumentText, error.InvalidDocumentMetadata, error.InvalidUtf8, error.InvalidUrlScheme, error.InvalidUrlUserInfo, error.MissingUrlHost, error.InvalidUrlHost, error.InvalidUrlPort, error.InvalidUrlCharacter, error.InvalidUrlEscape, error.InvalidHighlightInput, error.IncompatibleEmbeddingModel, error.SyntaxError, error.UnexpectedToken, error.UnknownField, error.MissingField, error.DuplicateField, error.InvalidEnumTag, error.InvalidNumber, error.Overflow => .bad_request,
        else => .internal_server_error,
    };
}

"""User-facing errors surfaced as exit code 2."""

class JacupError(Exception) {
    # A CLI, configuration, selection, or environment error.
    # Native builds cannot stringify exceptions; handlers read .message instead.
    has message: str;
}

def fail(message: str) -> JacupError {
    raise JacupError(message);
}

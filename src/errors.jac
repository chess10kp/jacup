"""User-facing errors surfaced as exit code 2."""

class JacupError(Exception) {
    # A CLI, configuration, selection, or environment error.
}

def fail(message: str) -> JacupError {
    raise JacupError(message);
}

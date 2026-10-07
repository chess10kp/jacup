"""Exact semantic versions: MAJOR.MINOR.PATCH[-PRERELEASE].

`jacup` only accepts exact versions. Ranges, `latest`, `v` prefixes, and
path-like values never parse, so they are rejected at every version entry
point; 'install latest' and 'update' resolve the literal 'latest' through the
release index (releases.latestVersionString) before any version is parsed.
"""

import from src.errors { JacupError }

def isDigit(ch: str) -> bool {
    return ch >= "0" and ch <= "9";
}

def allDigits(text: str) -> bool {
    if not text {
        return False;
    }
    for ch in text {
        if not isDigit(ch) {
            return False;
        }
    }
    return True;
}

def validNumericIdentifier(text: str) -> bool {
    return allDigits(text) and (len(text) == 1 or not text.startswith("0"));
}

def validPrerelease(text: str) -> bool {
    if not text {
        return False;
    }
    for ident in text.split(".") {
        if not ident {
            return False;
        }
        for ch in ident {
            if not isDigit(ch) and not (ch >= "A" and ch <= "Z") and not (ch >= "a" and ch <= "z") and ch != "-" {
                return False;
            }
        }
        if allDigits(ident) and not validNumericIdentifier(ident) {
            return False;
        }
    }
    return True;
}

obj Version {
    has major: int, minor: int, patch: int;
    has prerelease: str = "";

    def format() -> str {
        if self.prerelease {
            return f"{self.major}.{self.minor}.{self.patch}-{self.prerelease}";
        }
        return f"{self.major}.{self.minor}.{self.patch}";
    }

    def compare(other: Version) -> int {
        if self.major != other.major { return -1 if self.major < other.major else 1; }
        if self.minor != other.minor { return -1 if self.minor < other.minor else 1; }
        if self.patch != other.patch { return -1 if self.patch < other.patch else 1; }
        if self.isRelease() != other.isRelease() {
            return 1 if self.isRelease() else -1;
        }
        return Version.comparePrerelease(self.prerelease, other.prerelease);
    }

    def isRelease() -> bool {
        return self.prerelease == "";
    }

    static def compareIdentifier(a: str, b: str) -> int {
        aNumeric: bool = allDigits(a);
        bNumeric: bool = allDigits(b);
        if aNumeric and bNumeric {
            ai: int = int(a);
            bi: int = int(b);
            if ai != bi { return -1 if ai < bi else 1; }
            return 0;
        }
        if aNumeric != bNumeric {
            return -1 if aNumeric else 1;
        }
        if a == b { return 0; }
        return -1 if a < b else 1;
    }

    static def comparePrerelease(a: str, b: str) -> int {
        left: list[str] = a.split(".") if a else [];
        right: list[str] = b.split(".") if b else [];
        n: int = min(len(left), len(right));
        i: int = 0;
        while i < n {
            cmp: int = Version.compareIdentifier(left[i], right[i]);
            if cmp != 0 { return cmp; }
            i = i + 1;
        }
        if len(left) == len(right) { return 0; }
        return -1 if len(left) < len(right) else 1;
    }
}

def parseVersion(text: str) -> Version {
    pieces: list[str] = text.split("-");
    if len(pieces) > 2 {
        raise JacupError(
            f"invalid version '{text}': expected MAJOR.MINOR.PATCH with an optional "
            "-PRERELEASE suffix (e.g. 0.9.2, 1.0.0-rc.1); ranges, 'latest', and "
            "path-like values are not accepted"
        );
    }
    core: list[str] = pieces[0].split(".");
    if len(core) != 3 {
        raise JacupError(
            f"invalid version '{text}': expected MAJOR.MINOR.PATCH with an optional "
            "-PRERELEASE suffix (e.g. 0.9.2, 1.0.0-rc.1); ranges, 'latest', and "
            "path-like values are not accepted"
        );
    }
    if not validNumericIdentifier(core[0]) or not validNumericIdentifier(core[1]) or not validNumericIdentifier(core[2]) {
        raise JacupError(
            f"invalid version '{text}': expected MAJOR.MINOR.PATCH with an optional "
            "-PRERELEASE suffix (e.g. 0.9.2, 1.0.0-rc.1); ranges, 'latest', and "
            "path-like values are not accepted"
        );
    }
    prerelease: str = "";
    if len(pieces) == 2 {
        prerelease = pieces[1];
        if not validPrerelease(prerelease) {
            raise JacupError(
                f"invalid version '{text}': expected MAJOR.MINOR.PATCH with an optional "
                "-PRERELEASE suffix (e.g. 0.9.2, 1.0.0-rc.1); ranges, 'latest', and "
                "path-like values are not accepted"
            );
        }
    }
    return Version(
        major=int(core[0]),
        minor=int(core[1]),
        patch=int(core[2]),
        prerelease=prerelease
    );
}

def sortVersions(versions: list[Version]) -> list[Version] {
    result: list[Version] = list(versions);
    i: int = 1;
    while i < len(result) {
        item = result[i];
        j: int = i - 1;
        while j >= 0 and result[j].compare(item) > 0 {
            result[j + 1] = result[j];
            j = j - 1;
        }
        result[j + 1] = item;
        i = i + 1;
    }
    return result;
}

def sortVersionStrings(texts: list[str]) -> list[str] {
    parsed: list[Version] = [];
    for t in texts {
        parsed.append(parseVersion(t));
    }
    out: list[str] = [];
    for v in sortVersions(parsed) {
        out.append(v.format());
    }
    return out;
}

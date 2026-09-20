"""Exact semantic versions: MAJOR.MINOR.PATCH[-PRERELEASE].

`jacup` only accepts exact versions. Ranges, `latest`, `v` prefixes, and
path-like values never parse, so they are rejected at every entry point.
"""

import re;
import from src.errors { JacupError }

glob VERSION_PATTERN: str = (
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?$"
);

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

    def sortKey() -> tuple[int, int, int, int, tuple[tuple[int, int, str], ...]] {
        parts: list[tuple[int, int, str]] = [];
        for ident in self.prerelease.split(".") if self.prerelease else [] {
            parts.append(Version.identifierKey(ident));
        }
        return (self.major, self.minor, self.patch, 1 if self.isRelease() else 0, tuple(parts));
    }

    static def identifierKey(ident: str) -> tuple[int, int, str] {
        if ident.isdigit() {
            return (0, int(ident), "");
        }
        return (1, 0, ident);
    }

    static def comparePrerelease(a: str, b: str) -> int {
        left: list[tuple[int, int, str]] = [];
        for ident in a.split(".") if a else [] {
            left.append(Version.identifierKey(ident));
        }
        right: list[tuple[int, int, str]] = [];
        for ident in b.split(".") if b else [] {
            right.append(Version.identifierKey(ident));
        }
        n: int = min(len(left), len(right));
        i: int = 0;
        while i < n {
            if left[i] < right[i] { return -1; }
            if left[i] > right[i] { return 1; }
            i = i + 1;
        }
        if len(left) == len(right) { return 0; }
        return -1 if len(left) < len(right) else 1;
    }
}

def parseVersion(text: str) -> Version {
    m = re.fullmatch(VERSION_PATTERN, text);
    if not m {
        raise JacupError(
            f"invalid version '{text}': expected MAJOR.MINOR.PATCH with an optional "
            "-PRERELEASE suffix (e.g. 0.9.2, 1.0.0-rc.1); ranges, 'latest', and "
            "path-like values are not accepted"
        );
    }
    major: int = int(m.group(1));
    minor: int = int(m.group(2));
    patch: int = int(m.group(3));
    pre = m.group(5) or "";
    return Version(major=major, minor=minor, patch=patch, prerelease=pre);
}

def sortVersions(versions: list[Version]) -> list[Version] {
    result: list[Version] = list(versions);
    i: int = 1;
    while i < len(result) {
        item = result[i];
        j: int = i - 1;
        while j >= 0 and result[j].sortKey() > item.sortKey() {
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

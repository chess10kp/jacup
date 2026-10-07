"""Network bytes helper backed by the host curl executable."""

import os;
import from src.path_core { uniqueStamp }

def shellQuote(value: str) -> str {
    result: str = "'";
    for ch in value {
        if ch == "'" {
            result = result + "'\\''";
        } else {
            result = result + ch;
        }
    }
    return result + "'";
}

def:pub fetchBytes(url: str) -> bytes {
    tmp: str = os.path.join(
        "/tmp",
        f"jacup-net-{os.getpid()}-{uniqueStamp()}"
    );
    command: str = "curl --fail --silent --show-error --location --output " + shellQuote(tmp) + " " + shellQuote(url);
    if os.system(command) != 0 {
        raise OSError(f"curl failed while downloading {url}");
    }
    fh = open(tmp, "rb");
    try {
        data: bytes = fh.read();
    } finally {
        fh.close();
    }
    os.unlink(tmp);
    return data;
}

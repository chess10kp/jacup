"""Build-selected target constants.

The native release build replaces this file in its isolated build tree so the
same source can detect the artifact target without consulting a runtime.
"""

glob TARGET_OS: str = "linux",
     TARGET_ARCH: str = "x86_64";

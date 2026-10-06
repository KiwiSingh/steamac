import os
import logging

from ._version import __version__  # noqa: F401  `._version.__version__` imported but unused

logger = logging.getLogger("hidtools")
# If HID_DEBUG is set, set the base logger to verbose, triggering all child
# loggers to become verbose too.
if os.environ.get("HID_DEBUG", False):
    logger.setLevel(logging.DEBUG)

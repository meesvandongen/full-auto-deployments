import json
from urllib.request import urlopen


def double(value, base_url):
    with urlopen(f"{base_url}/api/double?value={value}", timeout=3) as response:
        result = json.load(response)["result"]
    if not isinstance(result, int):
        raise ValueError("Double provider returned a non-integer result")
    return result

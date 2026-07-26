"""Minimal JSONPath: $ and $.dotted.path only (D10)."""

def path_get(data: dict, path: str) -> any {
    if path == "$" or path == "" {
        return data;
    }
    cleaned = path;
    if cleaned.startswith("$.") {
        cleaned = cleaned[2:];
    } elif cleaned.startswith("$") {
        cleaned = cleaned[1:];
    }
    if cleaned == "" {
        return data;
    }
    cur: any = data;
    for key in cleaned.split(".") {
        if key == "" {
            continue;
        }
        if isinstance(cur, dict) and key in cur {
            cur = cur[key];
        } else {
            return {};
        }
    }
    return cur;
}

def path_set(data: dict, path: str, value: any) -> dict {
    if path == "$" or path == "" {
        if isinstance(value, dict) {
            return value as dict;
        }
        return {"value": value};
    }
    cleaned = path;
    if cleaned.startswith("$.") {
        cleaned = cleaned[2:];
    } elif cleaned.startswith("$") {
        cleaned = cleaned[1:];
    }
    keys = [k for k in cleaned.split(".") if k != ""];
    if len(keys) == 0 {
        if isinstance(value, dict) {
            return value as dict;
        }
        return {"value": value};
    }
    root_obj: dict = data;
    cur: dict = root_obj;
    i = 0;
    while i < len(keys) - 1 {
        k = keys[i];
        if k not in cur or not isinstance(cur[k], dict) {
            cur[k] = {};
        }
        cur = cur[k] as dict;
        i += 1;
    }
    cur[keys[len(keys) - 1]] = value;
    return root_obj;
}

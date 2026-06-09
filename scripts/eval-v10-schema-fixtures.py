#!/usr/bin/env python3
"""
Validate deterministic v10 planner-response schema fixtures.

This is a parser/schema gate, not a model eval. It reads the bundled
pace-fm-response-v10.schema.json artifact and checks every JSON fixture under
evals/v10-schema-fixtures for its expected schema-valid / schema-invalid result.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = REPO_ROOT / "leanring-buddy" / "Resources" / "v10-actions" / "pace-fm-response-v10.schema.json"
FIXTURE_DIR = REPO_ROOT / "evals" / "v10-schema-fixtures"


def validate_value(value: Any, schema: dict[str, Any], path: str = "$") -> list[str]:
    issues: list[str] = []

    expected_type = schema.get("type")
    if expected_type is not None and not value_matches_type(value, expected_type):
        return [f"{path} must be {expected_type}"]

    if "enum" in schema and value not in schema["enum"]:
        allowed = ", ".join(str(item) for item in schema["enum"])
        issues.append(f"{path} must be one of {allowed}")

    if "const" in schema and value != schema["const"]:
        issues.append(f"{path} must be {schema['const']}")

    if isinstance(value, dict):
        issues.extend(validate_object(value, schema, path))
    elif isinstance(value, list):
        issues.extend(validate_array(value, schema, path))

    for conditional_schema in schema.get("allOf", []):
        if_schema = conditional_schema.get("if")
        then_schema = conditional_schema.get("then")
        if if_schema and then_schema and conditional_matches(value, if_schema):
            issues.extend(validate_value(value, then_schema, path))

    return issues


def validate_object(value: dict[str, Any], schema: dict[str, Any], path: str) -> list[str]:
    issues: list[str] = []
    properties = schema.get("properties", {})
    required = schema.get("required", [])

    for required_key in required:
        if required_key not in value:
            issues.append(f"{path}.{required_key} is required")

    if schema.get("additionalProperties") is False:
        for key in sorted(set(value) - set(properties)):
            issues.append(f"{path}.{key} is not allowed")

    for key, property_schema in properties.items():
        if key in value:
            issues.extend(validate_value(value[key], property_schema, f"{path}.{key}"))

    return issues


def validate_array(value: list[Any], schema: dict[str, Any], path: str) -> list[str]:
    item_schema = schema.get("items")
    if not item_schema:
        return []

    issues: list[str] = []
    for index, item in enumerate(value):
        issues.extend(validate_value(item, item_schema, f"{path}[{index}]"))
    return issues


def value_matches_type(value: Any, expected_type: str) -> bool:
    if expected_type == "object":
        return isinstance(value, dict)
    if expected_type == "array":
        return isinstance(value, list)
    if expected_type == "string":
        return isinstance(value, str)
    if expected_type == "boolean":
        return isinstance(value, bool)
    if expected_type == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected_type == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected_type == "null":
        return value is None
    return False


def conditional_matches(value: Any, schema: dict[str, Any]) -> bool:
    if not isinstance(value, dict):
        return False

    properties = schema.get("properties", {})
    for key, property_schema in properties.items():
        if key not in value:
            return False
        if validate_value(value[key], property_schema, f"$.{key}"):
            return False
    return True


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as file_handle:
        return json.load(file_handle)


def main() -> int:
    schema = load_json(SCHEMA_PATH)
    fixture_paths = sorted(FIXTURE_DIR.glob("*.json"))
    if not fixture_paths:
        print(f"no v10 schema fixtures found in {FIXTURE_DIR}", file=sys.stderr)
        return 2

    failures: list[str] = []
    for fixture_path in fixture_paths:
        fixture = load_json(fixture_path)
        expected_valid = bool(fixture["valid"])
        response = fixture["response"]
        issues = validate_value(response, schema)
        actual_valid = not issues

        status = "PASS" if actual_valid == expected_valid else "FAIL"
        print(f"{status} {fixture_path.name} expected_valid={expected_valid} actual_valid={actual_valid}")

        if actual_valid != expected_valid:
            formatted_issues = "; ".join(issues) if issues else "no validation issues"
            failures.append(f"{fixture_path.name}: {formatted_issues}")

    if failures:
        print("\nSchema fixture failures:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"\nValidated {len(fixture_paths)} v10 schema fixture(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""The class vocabulary, loaded from the dataset the harvester wrote.

PIN: THE ROLE -> CATEGORY TABLE IS SWIFT'S, NOT OURS. Dataset/roles.json carries the
     category alongside each role precisely so this file never re-implements
     AXNodeCategory.category(role:). A second copy here would drift, and the
     category-accuracy metric would then be measuring agreement with the drift.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

NONE_ROLE = "none"


@dataclass(frozen=True)
class RoleTable:
    roles: tuple[str, ...]
    categories: tuple[str, ...]

    @property
    def class_count(self) -> int:
        return len(self.roles)

    def index(self, role: str) -> int | None:
        try:
            return self.roles.index(role)
        except ValueError:
            return None

    def category(self, index: int) -> str:
        return self.categories[index]

    def validate(self) -> "RoleTable":
        if self.roles[0] != NONE_ROLE:
            raise ValueError(f'class 0 must be "{NONE_ROLE}", got "{self.roles[0]}"')
        if len(set(self.roles)) != len(self.roles):
            raise ValueError("duplicate role in the table")
        return self

    @staticmethod
    def load(dataset_root: Path) -> "RoleTable":
        path = Path(dataset_root) / "roles.json"
        rows = json.loads(path.read_text())
        rows.sort(key=lambda row: row["index"])
        for expected, row in enumerate(rows):
            if row["index"] != expected:
                raise ValueError(f"roles.json is not densely indexed at {expected}")
        return RoleTable(
            roles=tuple(row["role"] for row in rows),
            categories=tuple(row["category"] for row in rows),
        ).validate()


# WHAT: What a role affords, as a coarsening of the role vocabulary.
# PIN:  A TABLE, NOT A SECOND HEAD. Affordance is a deterministic grouping of role —
#       press is button/link/checkbox/..., fill is the text-like ones — so a learned
#       head would predict a marginal the softmax already contains. Summing the group's
#       probabilities is the same quantity for no extra training, and it repairs exactly
#       the confusions that hurt most: link-vs-button and field-vs-combobox cost nothing
#       under the marginal, and both are the pairs the model gets wrong.
AFFORDANCES = {
    "press": [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXDisclosureTriangle", "AXTab",
        "AXRow",
    ],
    "fill": ["AXTextField", "AXTextArea", "AXComboBox"],
    "adjust": ["AXSlider"],
    "scroll": ["AXScrollArea"],
}


def affordance_of(role: str) -> str | None:
    """Which group a role belongs to, or None for the ones that afford nothing."""
    for name, roles in AFFORDANCES.items():
        if role in roles:
            return name
    return None


def affordance_groups(table: "RoleTable") -> dict[str, list[int]]:
    """The class indexes in each group, for a run's own vocabulary."""
    groups: dict[str, list[int]] = {}
    for name, roles in AFFORDANCES.items():
        indexes = [table.index(role) for role in roles]
        kept = [index for index in indexes if index is not None]
        if kept:
            groups[name] = sorted(kept)
    return groups

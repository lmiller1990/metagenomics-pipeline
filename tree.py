import csv
from graphviz import Digraph
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class TaxonNode:
    name: str
    rank: str
    depth: int
    children: list["TaxonNode"] = field(default_factory=list)


with Path("sample.report").open(newline="", encoding="utf8") as f:
    reader = csv.reader(f, delimiter="\t")
    stack: list[TaxonNode] = []
    roots: list[TaxonNode] = []

    for row in reader:
        perc, clade_reads, direct_reads, rank, taxid, name = row
        depth = len(name) - len(name.lstrip())
        depth = int(depth / 2)

        while len(stack) > depth:
            stack.pop()

        node = TaxonNode(name=name.strip(), rank=rank, depth=depth)

        if len(stack) != 0:
            stack[-1].children.append(node)
        else:
            roots.append(node)

        stack.append(node)


def print_tree(node, indent=""):
    print(f"{indent}{node.name}")
    for child in node.children:
        print_tree(child, indent + "  ")


for root in roots:
    print_tree(root)

# def add_node(dot: Digraph, node: TaxonNode):
#     dot.node(str(id(node)), f"{node.name}\n({node.rank})")
#     for child in node.children:
#         dot.edge(str(id(node)), str(id(child)))
#         add_node(dot, child)


# dot = Digraph()
# for root in roots:
#     add_node(dot, root)


# dot.render("taxonomy", format="png")

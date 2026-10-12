"""The architecture pages must describe everything that is built and every deployment step,
so a new resource, workflow step or chart template fails CI until it is documented."""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"

# Each OpenTofu folder and the page that describes it
INFRA_DOCS = {
    "infra/aws": "aws-architecture.md",
    "infra/eks": "aws-architecture.md",
    "infra/modules/aws-database": "aws-architecture.md",
    "infra/gcp": "gcp-architecture.md",
    "infra/gke": "gcp-architecture.md",
    "infra/modules/gcp-database": "gcp-architecture.md",
    "infra/azure": "azure-architecture.md",
    "infra/aks": "azure-architecture.md",
    "infra/modules/azure-database": "azure-architecture.md",
}

# Each deploy workflow and the page that walks through its steps
WORKFLOW_DOCS = {
    "deploy-aws.yml": "aws-architecture.md",
    "deploy-gcp.yml": "gcp-architecture.md",
    "deploy-azure.yml": "azure-architecture.md",
    "deploy-kubernetes.yml": "kubernetes-architecture.md",
}

BLOCK = re.compile(r'^(resource|data) "([a-z0-9_]+)" "([a-z0-9_]+)"|^module "([a-z0-9_]+)"', re.M)
STEP = re.compile(r"^ {6}- (name|uses): (.+)$", re.M)
JOB = re.compile(r"^ {2}([a-z][a-z0-9-]*):\s*$", re.M)
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def declared(folder: str) -> list[str]:
    """Every resource, data source and module call in a folder, as OpenTofu addresses it."""
    addresses = []
    for path in sorted((ROOT / folder).glob("*.tf")):
        for match in BLOCK.finditer(read(path)):
            kind, type_, name, module = match.groups()
            if module:
                addresses.append(f"module.{module}")
            elif kind == "data":
                addresses.append(f"data.{type_}.{name}")
            else:
                addresses.append(f"{type_}.{name}")
    return addresses


@pytest.mark.parametrize(("folder", "page"), INFRA_DOCS.items())
def test_every_resource_is_documented(folder, page):
    addresses = declared(folder)
    assert addresses, f"no OpenTofu blocks found in {folder}"
    text = read(DOCS / page)
    missing = [address for address in addresses if f"{address}" not in text]
    assert missing == [], f"docs/{page} doesn't describe {missing} from {folder}"


def steps(workflow: str) -> list[str]:
    """Each step's name, or the action it uses when it has no name."""
    found = []
    for kind, value in STEP.findall(read(ROOT / ".github" / "workflows" / workflow)):
        found.append(value.strip() if kind == "name" else value.split("@")[0].strip())
    return found


@pytest.mark.parametrize(("workflow", "page"), WORKFLOW_DOCS.items())
def test_every_deployment_step_is_documented(workflow, page):
    names = steps(workflow)
    assert len(names) >= 10, f"expected the steps of {workflow}"
    text = read(DOCS / page)
    missing = [name for name in names if name not in text]
    assert missing == [], f"docs/{page} doesn't explain these steps of {workflow}: {missing}"


def test_every_chart_template_is_documented():
    chart = ROOT / "deploy" / "helm" / "multi-cloud-app"
    templates = sorted(
        str(path.relative_to(chart)) for path in (chart / "templates").rglob("*") if path.is_file()
    )
    text = read(DOCS / "kubernetes-architecture.md")
    missing = [template for template in templates if f"`{template}`" not in text]
    assert missing == [], f"docs/kubernetes-architecture.md doesn't list {missing}"


def test_every_ci_job_is_documented():
    workflow = read(ROOT / ".github" / "workflows" / "ci.yml")
    jobs = JOB.findall(workflow.split("\njobs:\n", 1)[1])
    assert "ci-passed" in jobs
    text = read(DOCS / "architecture.md")
    missing = [job for job in jobs if f"| `{job}` |" not in text]
    assert missing == [], f"docs/architecture.md's CI table doesn't list {missing}"


def slug(heading: str) -> str:
    """GitHub's anchor for a heading."""
    text = re.sub(r"[^\w\- ]", "", heading.strip().lower())
    return text.replace(" ", "-")


def anchors(path: Path) -> set[str]:
    text = read(path)
    headings = {slug(h) for h in re.findall(r"^#{1,6} (.+)$", text, re.M)}
    return headings | set(re.findall(r'<a id="([^"]+)"></a>', text))


@pytest.mark.parametrize("page", sorted(p.name for p in DOCS.glob("*.md")) + ["../README.md"])
def test_links_and_anchors_resolve(page):
    source = (DOCS / page).resolve()
    broken = []
    for target in LINK.findall(read(source)):
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        path, _, anchor = target.partition("#")
        resolved = (source.parent / path).resolve() if path else source
        if not resolved.exists():
            broken.append(target)
        elif anchor and resolved.suffix == ".md" and anchor not in anchors(resolved):
            broken.append(target)
    assert broken == [], f"{page} links to missing files or anchors: {broken}"

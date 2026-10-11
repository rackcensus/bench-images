import importlib.metadata
import json
import platform
import random
import sys

import django

PAGES_PER_TYPE = 50
SNIPPETS = 20
USERNAME = "admin"
PASSWORD = "changeme"
SEARCH_TERMS = ["bread", "sourdough", "rye", "baguette", "flour", "london"]


def live_paths(model):
    return sorted(page.url for page in model.objects.live().public())


def fetch(client, path):
    response = client.get(path, HTTP_HOST="wagtail")
    if response.status_code != 200:
        raise SystemExit(f"{path} answered {response.status_code}")
    return len(response.content)


def seed_random():
    from django.core.management import call_command

    random.seed(20261010)
    call_command("create_random_data", PAGES_PER_TYPE, SNIPPETS, 0)


def write_manifest(target):
    from django.contrib.auth import get_user_model
    from django.test import Client
    from wagtail.images.models import Image, Rendition
    from wagtail.models import Page

    from bakerydemo.blog.models import BlogIndexPage, BlogPage
    from bakerydemo.breads.models import BreadPage, BreadsIndexPage
    from bakerydemo.locations.models import LocationPage

    user = get_user_model().objects.get(username=USERNAME)
    user.set_password(PASSWORD)
    user.save()

    client = Client()
    pages = list(Page.objects.live().public().filter(depth__gt=1).specific())
    crawled = sum(fetch(client, page.url) for page in pages)
    for term in SEARCH_TERMS:
        fetch(client, f"/search/?q={term}")
    print(f"crawled {len(pages)} pages, {crawled // 1024} KB of html, {Rendition.objects.count()} image renditions")

    client.force_login(user)
    editable = sorted(BreadPage.objects.live().values_list("id", flat=True))
    for page_id in editable[:3]:
        response = client.get(f"/admin/pages/{page_id}/edit/", HTTP_HOST="wagtail")
        if response.status_code != 200:
            raise SystemExit(f"editing page {page_id} answered {response.status_code}")

    breads_index = BreadsIndexPage.objects.live().get()
    data = {
        "home_path": "/",
        "blog_index_path": BlogIndexPage.objects.live().get().url,
        "blog_paths": live_paths(BlogPage),
        "bread_paths": live_paths(BreadPage),
        "location_paths": live_paths(LocationPage),
        "search_terms": SEARCH_TERMS,
        "explorer_page_id": breads_index.id,
        "edit_page_ids": editable,
        "username": USERNAME,
        "password": PASSWORD,
        "counts": {
            "pages": len(pages),
            "blog_posts": BlogPage.objects.live().count(),
            "breads": BreadPage.objects.live().count(),
            "locations": LocationPage.objects.live().count(),
            "images": Image.objects.count(),
            "renditions": Rendition.objects.count(),
        },
        "versions": {
            "wagtail": importlib.metadata.version("wagtail"),
            "django": django.__version__,
            "python": platform.python_version(),
            "uwsgi": importlib.metadata.version("uwsgi"),
        },
    }
    for key in ("blog_paths", "bread_paths", "location_paths", "edit_page_ids"):
        if not data[key]:
            raise SystemExit(f"the seed has no {key}")
    with open(target, "w") as handle:
        json.dump(data, handle, indent=2)


def main(argv):
    django.setup()
    if argv[1] == "random":
        seed_random()
    elif argv[1] == "manifest":
        write_manifest(argv[2])
    else:
        raise SystemExit(f"unknown seed step {argv[1]}")


if __name__ == "__main__":
    main(sys.argv)

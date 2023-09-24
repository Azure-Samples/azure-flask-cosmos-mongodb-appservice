import os
import pathlib

import mongoengine as engine
import pytest
from flask import url_for

from flaskapp import create_app, seeder


@pytest.fixture(scope="session")
def app():
    """Session-wide test `Flask` application."""
    # set up the test database
    dbuser = os.environ["MONGODB_USERNAME"]
    dbpass = os.environ["MONGODB_PASSWORD"]
    dbhost = os.environ["MONGODB_HOST"]
    dbname = os.environ["MONGODB_DATABASE"]
    config_override = {
        "TESTING": True,
        "DATABASE_URI": f"mongodb://{dbuser}:{dbpass}@{dbhost}/{dbname}?authSource=admin",
    }
    app = create_app(config_override)
    db = engine.connect(host=app.config.get("DATABASE_URI"))  # noqa: F841
    seeder.seed_data(pathlib.Path(__file__).parent.parent / "seed_data.json", drop=True)

    # establish an application context before running the tests
    yield app

    # remove the test database
    db.drop_database("test")


@pytest.fixture(scope="function")
def live_server_url(app, live_server):
    """Returns the url of the live server"""
    return url_for("pages.index", _external=True)

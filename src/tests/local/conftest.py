import os
import pathlib
from multiprocessing import Process

import ephemeral_port_reserve
import mongoengine as engine
import pytest
from flask import Flask

from flaskapp import create_app, seeder


def run_server(app: Flask, port: int):
    app.run(port=port, debug=False)


@pytest.fixture(scope="session")
def app_with_db():
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
    seeder.seed_data(pathlib.Path(__file__).parent.parent.parent / "seed_data.json", drop=True)

    # establish an application context before running the tests
    yield app

    # remove the test database
    db.drop_database("test")


@pytest.fixture(scope="session")
def live_server_url(app_with_db):
    """Returns the url of the live server"""

    # Start the process
    hostname = ephemeral_port_reserve.LOCALHOST
    free_port = ephemeral_port_reserve.reserve(hostname)
    proc = Process(
        target=run_server,
        args=(
            app_with_db,
            free_port,
        ),
        daemon=True,
    )
    proc.start()

    # Return the URL of the live server
    yield f"http://{hostname}:{free_port}"

    # Clean up the process
    proc.kill()

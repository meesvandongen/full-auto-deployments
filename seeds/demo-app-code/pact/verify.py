import os
from urllib.parse import urlsplit

from pact import Verifier


provider_url = os.environ["PROVIDER_URL"]
verifier = (
    Verifier("demo-app", host=urlsplit(provider_url).hostname)
    .add_transport(url=provider_url)
    .broker_source(os.environ["PACT_BROKER_BASE_URL"], selector=True)
    .include_pending()
    .consumer_version(main_branch=True)
    .consumer_version(deployed_or_released=True)
    .build()
)
verifier.set_publish_options(version=os.environ["PROVIDER_VERSION"], branch="main")
verifier.verify()

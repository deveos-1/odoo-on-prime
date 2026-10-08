# syntax=docker/dockerfile:1
############################################
# Odoo 18.0 - production multi-tenant image
# Built for deployment on Render.com (free tier)
#
# Render's free instances have a very small ephemeral disk quota
# (effectively well under 1GB). This is a multi-stage build so build-only
# tools (compilers, -dev headers) never end up in the final image, and
# .dockerignore strips tests/docs/unused translations from the build
# context, keeping the shipped image as small as possible.
############################################

# ---- Stage 1: build Python deps + collect them in a venv -----------------
FROM python:3.12-slim-bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libffi-dev \
        libjpeg-dev \
        libldap2-dev \
        libpq-dev \
        libsasl2-dev \
        libxml2-dev \
        libxslt1-dev \
        python3-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /opt/odoo
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir psycopg2-binary

# ---- Stage 2: slim runtime image -----------------------------------------
FROM python:3.12-slim-bookworm

ENV LANG=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive \
    PATH="/opt/venv/bin:$PATH"

# --- Runtime-only system dependencies (no compilers/-dev headers) ---------
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        fonts-dejavu-core \
        libjpeg62-turbo \
        libldap-2.5-0 \
        libpq5 \
        libsasl2-2 \
        libxml2 \
        libxslt1.1 \
        xfonts-75dpi \
        xfonts-base \
        zlib1g \
    && curl -sSL https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb \
        -o /tmp/wkhtmltox.deb \
    && apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb \
    && rm -rf /tmp/wkhtmltox.deb \
    && rm -rf /var/lib/apt/lists/*

# --- Odoo user + directories -------------------------------------------
RUN useradd -ms /bin/bash odoo \
    && mkdir -p /var/lib/odoo /etc/odoo /mnt/extra-addons \
    && chown -R odoo:odoo /var/lib/odoo /etc/odoo /mnt/extra-addons

COPY --from=builder --chown=odoo:odoo /opt/venv /opt/venv

WORKDIR /opt/odoo

# --- Odoo source (single COPY --chown layer; a separate `chown -R` RUN
# layer would duplicate the entire tree on overlay storage, roughly
# doubling image size for no benefit) -------------------------------------
COPY --chown=odoo:odoo . /opt/odoo

RUN chmod +x /opt/odoo/infra/entrypoint.sh

USER odoo

EXPOSE 8069

ENTRYPOINT ["/opt/odoo/infra/entrypoint.sh"]
CMD ["odoo"]

# syntax=docker/dockerfile:1
############################################
# Odoo 18.0 - production multi-tenant image
# Built for deployment on Render.com (free tier)
############################################
FROM python:3.12-slim-bookworm

ENV LANG=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive

# --- System dependencies ---------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        curl \
        fonts-noto-cjk \
        gnupg \
        libffi-dev \
        libjpeg-dev \
        libldap2-dev \
        libpq-dev \
        libsasl2-dev \
        libxml2-dev \
        libxslt1-dev \
        libxslt1.1 \
        node-less \
        python3-dev \
        xfonts-75dpi \
        xfonts-base \
        zlib1g-dev \
    && curl -sSL https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb \
        -o /tmp/wkhtmltox.deb \
    && apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb \
    && rm -rf /tmp/wkhtmltox.deb \
    && rm -rf /var/lib/apt/lists/*

# --- Odoo user + directories -------------------------------------------
RUN useradd -ms /bin/bash odoo \
    && mkdir -p /var/lib/odoo /etc/odoo /mnt/extra-addons \
    && chown -R odoo:odoo /var/lib/odoo /etc/odoo /mnt/extra-addons

WORKDIR /opt/odoo

# --- Python dependencies ----------------------------------------------
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir psycopg2-binary

# --- Odoo source ---------------------------------------------------------
COPY . /opt/odoo

# --- Multi-tenant entrypoint / config -----------------------------------
RUN chmod +x /opt/odoo/infra/entrypoint.sh \
    && chown -R odoo:odoo /opt/odoo /etc/odoo /var/lib/odoo /mnt/extra-addons

USER odoo

EXPOSE 8069

ENTRYPOINT ["/opt/odoo/infra/entrypoint.sh"]
CMD ["odoo"]

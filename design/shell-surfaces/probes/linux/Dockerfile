FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb dbus-x11 at-spi2-core python3-pyatspi python3-gi \
      gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 \
      xfce4-panel xfce4-session xfconf \
      libglib2.0-bin procps ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY dump.py /dump.py
COPY trayapp.py /trayapp.py
COPY run.sh /run.sh
RUN chmod +x /run.sh
CMD ["/run.sh"]

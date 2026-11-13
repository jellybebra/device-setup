"""Relay helpers without importing the discovery controller."""
from runtime import Core

class RouterCore(Core):
    def __init__(self, *args, mark=255, **kwargs):
        self.mark = mark
        super().__init__(*args, **kwargs)

    def configuration(self):
        config = super().configuration()
        config['outbounds'][1]['streamSettings']['sockopt']['mark'] = self.mark
        return config

    def outbound(self, node):
        config = super().outbound(node)
        config['streamSettings'].setdefault('sockopt', {})['mark'] = self.mark
        return config


class DataLock:
    def __init__(self, directory):
        import fcntl
        self.stream = (directory / 'service.lock').open('a')
        try:
            fcntl.flock(self.stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.stream.close()
            raise RuntimeError('Сервис с этой папкой данных уже запущен') from None

    def close(self):
        self.stream.close()

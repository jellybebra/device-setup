"""OS-protected subscription keys; existing Windows DPAPI blobs remain readable."""
import base64
import ctypes
import sys
import uuid


def protect(value, decrypt=False):
    if sys.platform == 'darwin':
        from keyring.backends.macOS import Keyring
        vault = Keyring()
        if decrypt:
            if not value.startswith('keychain:'):
                raise ValueError('Ключ Windows нельзя открыть на Mac. Введите ключ подписки заново.')
            secret = vault.get_password('RealityFinder', value[9:])
            if secret is None: raise ValueError('Ключ подписки отсутствует в Keychain')
            return secret
        name = uuid.uuid4().hex
        vault.set_password('RealityFinder', name, value)
        return 'keychain:' + name
    if sys.platform != 'win32':
        raise RuntimeError('Защищённые ключи поддерживаются на Windows и macOS')
    from ctypes import wintypes
    class Blob(ctypes.Structure):
        _fields_ = [('size', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_ubyte))]
    data = base64.b64decode(value) if decrypt else value.encode()
    buf = ctypes.create_string_buffer(data)
    src = Blob(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_ubyte))); dst = Blob()
    api = ctypes.windll.crypt32.CryptUnprotectData if decrypt else ctypes.windll.crypt32.CryptProtectData
    api.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                   ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    api.restype = wintypes.BOOL
    if not api(ctypes.byref(src), None, None, None, None, 1, ctypes.byref(dst)):
        raise OSError('Не удалось открыть защищённый ключ Windows')
    try:
        result = ctypes.string_at(dst.data, dst.size)
        return result.decode() if decrypt else base64.b64encode(result).decode()
    finally:
        ctypes.windll.kernel32.LocalFree.argtypes = [ctypes.c_void_p]
        ctypes.windll.kernel32.LocalFree(dst.data)

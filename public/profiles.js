const authState = {
  role: 'user',
  isAdmin: false,
  canManage: false
};

function setAdminError(message = '') {
  const errorNode = document.getElementById('admin-login-error');
  if (!errorNode) return;
  errorNode.hidden = !message;
  errorNode.textContent = message;
}

function applyAuthUi() {
  const isAdmin = Boolean(authState.isAdmin);
  document.body.dataset.role = isAdmin ? 'admin' : 'user';
  document.querySelectorAll('[data-admin-only]').forEach((element) => {
    element.classList.toggle('is-hidden-by-role', !isAdmin);
  });

  const roleBadge = document.getElementById('admin-role-badge');
  if (roleBadge) {
    roleBadge.textContent = isAdmin ? 'Администратор' : 'Пользователь';
  }

  const statusNode = document.getElementById('admin-auth-status');
  if (statusNode) {
    statusNode.textContent = isAdmin
      ? 'Режим администратора: управление профилями разблокировано.'
      : 'Только администратор может управлять профилями.';
  }

  const loginButton = document.getElementById('admin-login-btn');
  if (loginButton) {
    loginButton.hidden = isAdmin;
    loginButton.classList.toggle('is-hidden-by-role', isAdmin);
  }

  const logoutButton = document.getElementById('admin-logout-btn');
  if (logoutButton) {
    logoutButton.hidden = !isAdmin;
    logoutButton.classList.toggle('is-hidden-by-role', !isAdmin);
  }

  const loginKey = document.getElementById('admin-login-key');
  if (loginKey) {
    loginKey.hidden = isAdmin;
    loginKey.disabled = isAdmin;
    loginKey.classList.toggle('is-hidden-by-role', isAdmin);
    if (isAdmin) {
      loginKey.value = '';
    }
  }
}

async function refreshAuthState({ silent = false } = {}) {
  try {
    const response = await fetch('/api/auth/me', { cache: 'no-store' });
    if (!response.ok) {
      throw new Error(`Auth state request failed: ${response.status}`);
    }
    const payload = await response.json();
    authState.role = payload.role || 'user';
    authState.isAdmin = Boolean(payload.isAdmin);
    authState.canManage = Boolean(payload.canManage);
    applyAuthUi();
    if (!silent) {
      setAdminError('');
    }
    if (authState.isAdmin) {
      await loadProfiles();
    }
  } catch (error) {
    console.error('Failed to refresh auth state', error);
    authState.role = 'user';
    authState.isAdmin = false;
    authState.canManage = false;
    applyAuthUi();
    if (!silent) {
      setAdminError('Не удалось обновить статус авторизации.');
    }
  }
}

async function loginAdmin(event) {
  event.preventDefault();
  const apiKey = (document.getElementById('admin-login-key')?.value || '').trim();
  if (!apiKey) {
    setAdminError('Введите ADMIN_API_KEY.');
    return;
  }
  setAdminError('');
  const response = await fetch('/api/auth/admin/login', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ apiKey })
  });
  if (!response.ok) {
    setAdminError('Ошибка входа администратора. Проверьте ключ.');
    return;
  }
  await refreshAuthState({ silent: true });
}

async function logoutAdmin() {
  try {
    await fetch('/api/auth/logout', { method: 'POST' });
  } catch (error) {
    console.error('Admin logout failed', error);
  }
  await refreshAuthState({ silent: true });
  setAdminError('');
}

async function loadProfiles() {
  if (!authState.isAdmin) return;
  const res = await fetch('/api/profiles');
  const profiles = (await res.json()).sort((a, b) => (a.name || '').localeCompare(b.name || '', 'ru'));
  const list = document.getElementById('profile-list');
  if (!list) return;
  list.innerHTML = '';
  profiles.forEach((profile) => {
    const li = document.createElement('li');
    li.innerHTML = `<div>${profile.name}</div><small>${profile.voice || 'ash'} · ${profile.mood || 'neutral'}</small>`;
    li.className = 'profile-item';
    li.addEventListener('click', () => selectProfile(profile));
    list.appendChild(li);
  });
}

function selectProfile(profile) {
  document.getElementById('profile-id').value = profile.id;
  document.getElementById('profile-name').value = profile.name || '';
  document.getElementById('profile-voice').value = profile.voice || '';
  document.getElementById('profile-mood').value = profile.mood || '';
  document.getElementById('profile-rules').value = profile.rules || '';
  document.getElementById('profile-instructions').value = profile.instructions || '';
}

async function saveProfile(event) {
  event.preventDefault();
  if (!authState.isAdmin) {
    setAdminError('Сначала войдите как администратор.');
    return;
  }

  const id = document.getElementById('profile-id').value;
  const payload = {
    name: document.getElementById('profile-name').value,
    voice: document.getElementById('profile-voice').value,
    mood: document.getElementById('profile-mood').value,
    rules: document.getElementById('profile-rules').value,
    instructions: document.getElementById('profile-instructions').value
  };
  const response = await fetch(id ? `/api/profiles/${id}` : '/api/profiles', {
    method: id ? 'PUT' : 'POST',
    headers: {
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(payload)
  });
  if (response.status === 401) {
    await refreshAuthState({ silent: true });
    setAdminError('Требуется активная админ-сессия.');
    return;
  }
  if (!response.ok) {
    throw new Error('Не удалось сохранить профиль.');
  }
  await loadProfiles();
  document.getElementById('profile-form').reset();
  document.getElementById('profile-id').value = '';
}

function newProfile() {
  if (!authState.isAdmin) {
    setAdminError('Сначала войдите как администратор.');
    return;
  }
  document.getElementById('profile-form').reset();
  document.getElementById('profile-id').value = '';
}

document.getElementById('profile-form').addEventListener('submit', saveProfile);
document.getElementById('new-profile').addEventListener('click', newProfile);
document.getElementById('admin-login-form').addEventListener('submit', loginAdmin);
document.getElementById('admin-logout-btn').addEventListener('click', logoutAdmin);

applyAuthUi();
refreshAuthState({ silent: true });

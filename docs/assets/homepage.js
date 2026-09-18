const toggle = document.querySelector('.nav-toggle');
const sidebar = document.querySelector('.sidebar');

toggle?.addEventListener('click', () => {
  const isOpen = sidebar.classList.toggle('open');
  toggle.setAttribute('aria-expanded', String(isOpen));
  toggle.textContent = isOpen ? 'CLOSE' : 'MENU';
});

document.addEventListener('click', (event) => {
  if (!sidebar.classList.contains('open')) return;
  if (sidebar.contains(event.target) || toggle.contains(event.target)) return;
  sidebar.classList.remove('open');
  toggle.setAttribute('aria-expanded', 'false');
  toggle.textContent = 'MENU';
});

document.querySelectorAll('.copy-button').forEach((button) => {
  button.addEventListener('click', async () => {
    const target = document.getElementById(button.dataset.copy);
    try {
      await navigator.clipboard.writeText(target.innerText);
      button.textContent = 'COPIED';
      button.classList.add('copied');
      setTimeout(() => {
        button.textContent = 'COPY';
        button.classList.remove('copied');
      }, 1600);
    } catch {
      button.textContent = 'SELECT';
    }
  });
});




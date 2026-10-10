export function readNavigation(): { id: string | null; token: string | null } {
  const url = new URL(location.href);
  return {
    id: url.searchParams.get('playlist'),
    token: new URLSearchParams(url.hash.slice(1)).get('share'),
  };
}
export function selectNavigation(id: string, token: string | null): void {
  const url = new URL(location.href);
  const publicLink = url.searchParams.get('playlist') === id;
  url.search = '';
  url.hash = '';
  if (token) url.hash = 'share=' + token;
  else if (publicLink) url.searchParams.set('playlist', id);
  history.replaceState(null, '', url);
}

/** Первые буквы имени и стабильный цвет аватарки без изображения. */
export function avatar(name: string): { initials: string; color: string } {
  const words = name.trim().split(/\s+/).filter(Boolean);
  const initials =
    words
      .slice(0, 2)
      .map((word) => [...word][0])
      .join('')
      .toLocaleUpperCase() || 'M';
  const colors = ['#1967d2', '#137333', '#b06000', '#a142f4', '#c5221f', '#007b83'];
  let hash = 0;

  for (const character of name) hash = (hash * 31 + character.codePointAt(0)!) >>> 0;

  return { initials, color: colors[hash % colors.length] };
}

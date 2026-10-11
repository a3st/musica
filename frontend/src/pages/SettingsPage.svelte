<script lang="ts">
  import { getApplication } from '../app/context';
  import SettingsPanel from '../features/settings/ui/SettingsPanel.svelte';

  const app = getApplication();
</script>

<SettingsPanel
  settings={app.settings}
  language={app.language}
  theme={app.theme}
  close={() => (app.settingsOpen = false)}
/>

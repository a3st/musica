import { createContext } from 'svelte';
import type { Application } from './state.svelte';
export const [getApplication, setApplication] = createContext<Application>();

import { value } from './helper.js';
export function mount(context) {
  context.container.dataset.helper = value;
  context.container.textContent = value;
  return () => { delete context.container.dataset.helper; };
}

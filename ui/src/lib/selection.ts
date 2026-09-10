// Match the shared selection owner's whole-round automatic operation.
export function automaticSelectionCopy(paused: boolean) {
  return paused ? {
    title: '恢复自动选优',
    description: '将解除各自动出口的手动保持，重新测速，并按地区切换门槛恢复整轮自动选优。',
    confirmLabel: '恢复自动选优',
  } : {
    title: '重新选优',
    description: '将统一测速，再按各出口资格和地区切换门槛选择。当前地区健康时，小幅延迟差异不会导致换区；如需立即改用某地区，请使用“指定地区”。',
    confirmLabel: '开始选优',
  };
}

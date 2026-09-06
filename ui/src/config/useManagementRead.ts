import { useCallback, useEffect, useRef, useState } from 'react';
import type { NetFleetClient } from '../types';

type ReadMethod = 'network' | 'maintenance' | 'diagnostics';
type ReadResult<M extends ReadMethod> = Awaited<ReturnType<NetFleetClient[M]>>;

export function useManagementRead<M extends ReadMethod>(client: NetFleetClient | undefined, method: M) {
  const [data, setData] = useState<ReadResult<M> | null>(null);
  const [loading, setLoading] = useState(Boolean(client));
  const [error, setError] = useState<string | null>(null);
  const request = useRef(0);
  const refresh = useCallback(async () => {
    if (!client) return;
    const id = ++request.current;
    setLoading(true);
    setError(null);
    try {
      const result = await client[method]() as ReadResult<M>;
      if (id === request.current) setData(result);
    } catch (reason) {
      if (id === request.current) setError(reason instanceof Error ? reason.message : '设备管理信息读取失败');
    } finally {
      if (id === request.current) setLoading(false);
    }
  }, [client, method]);

  useEffect(() => {
    setData(null);
    void refresh();
    return () => { request.current++; };
  }, [refresh]);
  return { data, loading, error, refresh };
}

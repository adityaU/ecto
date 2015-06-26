defmodule Ecto.Adapters.Pool do
  @modueldoc"""
  Behaviour for using a pool of connections.
  """

  use Behaviour

  @typedoc """
  A pool process
  """
  @type t :: atom | pid

  @typedoc """
  Opaque connection reference.

  Use inside `run/4` and `transaction/4` to retrieve the connection module and
  pid or break the transaction.
  """
  @opaque ref :: {__MODULE__, module, t}

  @typedoc """
  The mode of a transaction.

  Supported modes:

    * `:raw` - direct transaction without a sandbox
    * `:sandbox` - transaction inside a sandbox
  """
  @type mode :: :raw | :sandbox

  @typedoc """
  The depth of nested transactions.
  """
  @type depth :: non_neg_integer

  @typedoc """
  The time in microseconds spent waiting for a connection from the pool.
  """
  @type queue_time :: non_neg_integer

  @doc """
  Start a pool of connections.

  `module` is the connection module, which should define the
  `Ecto.Adapters.Connection` callbacks, and `opts` are its (and the pool's)
  options.

  A pool should support the following options:

    * `:name` - The name of the pool
    * `:size` - The number of connections to keep in the pool

  Returns `{:ok, pid}` on starting the pool.

  Returns `{:error, reason}` if the pool could not be started. If the `reason`
  is  {:already_started, pid}}` a pool with the same name has already been
  started.
  """
  defcallback start_link(module, opts) ::
    {:ok, pid} | {:error, any} when opts: Keyword.t

  @doc """
  Stop a pool.
  """
  defcallback stop(t) :: :ok

  @doc """
  Checkout a worker/connection from the pool.

  The connection should not be closed if the calling process exits without
  returning the connection.

  Returns `{mode, worker, conn, queue_time}` on success, where `worker` is the
  worker term and conn is a 2-tuple contain the connection's module and
  pid. The `conn` tuple can be retrieved inside a `transaction/4` with
  `connection/1`.

  Returns `{:error, :noproc}` if the pool is not alive and
  `{:error, :noconnect}` if a connection is not available.
  """
  defcallback checkout(t, timeout) ::
    {mode, worker, conn, queue_time} |
    {:error, :noproc | :noconnect} when worker: any, conn: {module, pid}

  @doc """
  Checkin a worker/connection to the pool.

  Called when the top level `run/4` finishes, if `break/2` was not called
  inside the fun.
  """
  defcallback checkin(t, worker, timeout) :: :ok when worker: any

  @doc """
  Break the current transaction or run.

  Called when the function has failed and the connection should no longer be
  available to to the calling process. When in `:raw` mode the connection
  should reset.
  """
  defcallback break(t, worker, timeout) :: :ok when worker: any

  @doc """
  Open a transaction with a connection from the pool.

  The connection should be closed if the calling process exits without
  returning the connection when in `:raw` mode.

  Returns `{mode, worker, conn, queue_time}` on success, where `worker` is the
  worker term and conn is a 2-tuple contain the connection's module and
  pid. The `conn` tuple can be retrieved inside a `transaction/4` with
  `connection/2`.

  Returns `{:error, :noproc}` if the pool is not alive and
  `{:error, :noconnect}` if a connection is not available.
  """
  defcallback open_transaction(t, timeout) ::
    {mode, worker, conn, queue_time} |
    {:error, :noproc | :noconnect} when worker: any, conn: {module, pid}

  @doc """
  Sets the mode of transaction to `mode`.
  """
  defcallback transaction_mode(t, worker, mode, timeout) ::
    :ok | {:error, :noconnect} when worker: any

  @doc """
  Close the transaction and signal to the worker the work with the connection
  is complete.

  Called once the transaction at `depth` `1` is finished, if the transaction
  is not broken with `break/2`.
  """
  defcallback close_transaction(t, worker, timeout) :: :ok when worker: any

  @doc """
  Run a fun using a connection from a pool.

  Once inside a `run/4` any call to `run/4` for the same pool will reuse the
  same worker/connection. If `break/2` is invoked, all operations will return
  `{:error, :noconnect}` until the end of the top level run.

  Returns the value returned by the function wrapped in a tuple
  as `{:ok, value}`. A fun can be run inside or outside a transaction and
  nested. The `depth` shows the depth of nested transactions for the module/pool
  combination - outside a transaction the `depth` is `0`.

  Returns `{:error, :noproc}` if the pool is not alive or `{:error, :noconnect}`
  if no connection is available.

  ## Examples

      Pool.run(mod, pool, timeout,
        fn(ref, :sandbox, 0, _queue_time) -> :sandboxed_run end)

      Pool.transaction(mod, pool, timeout,
        fn(ref, :raw, 1, _queue_time) ->
          {:ok, :nested} =
            Pool.run(mod, pool, timeout, fn(ref, :raw, 1, nil) ->
              :nested
            end)
        end)

      Pool.run(mod, :pool1, timeout,
        fn(ref, :raw, 0, _queue_time1) ->
          {:ok, :different_pool} =
            Pool.run(mod, :pool2, timeout,
              fn(ref, :raw, 0, _queue_time2) -> :different_pool end)
        end)

  """
  @spec run(module, t, timeout,
  ((ref, mode, depth, queue_time | nil) -> result)) ::
    {:ok, result} | {:error, :noproc | :noconnect} when result: var
  def run(pool_mod, pool, timeout, fun) do
    ref = {__MODULE__, pool_mod, pool}
    case Process.get(ref) do
      nil ->
        run(pool_mod, pool, ref, timeout, fun)
      %{conn: conn} ->
        do_run(ref, conn, nil, timeout, fun)
      %{} ->
        {:error, :noconnect}
    end
  end

  @doc """
  Carry out a transaction using a connection from a pool.

  Once a transaction is opened, all following calls to `run/4` or
  `transaction/4` will use the same connection/worker. If `break/2` is invoked,
  all operations will return `{:error, :noconnect}` until the end of the
  top level transaction.

  A transaction returns the value returned by the function wrapped in a tuple
  as `{:ok, value}`. Transactions can be nested and the `depth` shows the depth
  of nested transaction for the module/pool combination.

  Returns `{:error, :noproc}` if the pool is not alive, `{:error, :noconnect}`
  if no connection is available or `{:error, :notransaction}` if called inside
  a `run/4` fun at depth `0`.

  ## Examples

      Pool.transaction(mod, pool, timeout,
        fn(ref, :sandbox, 1, _queue_time) -> :sandboxed_transaction end)

      Pool.transaction(mod, pool, timeout,
        fn(ref, :raw, 1, _queue_time) ->
          {:ok, :nested} =
            Pool.transaction(mod, pool, timeout, fn(ref, :raw, 1, nil) ->
              :nested
            end)
        end)

      Pool.transaction(mod, :pool1, timeout,
        fn(ref, :raw, 1, _queue_time1) ->
          {:ok, :different_pool} =
            Pool.transaction(mod, :pool2, timeout,
              fn(ref, :raw, 1, _queue_time2) -> :different_pool end)
        end)

      Pool.run(mod, pool, timeout,
        fn(ref, :raw, 0, _queue_time) ->
          {:error, :notransaction} =
            Pool.transaction(mod, pool, timeout, fn(_, _, _, _) -> end)
        end)

  """
  @spec transaction(module, t, timeout,
  ((ref, mode, depth, queue_time | nil) -> result)) ::
    {:ok, result} | {:error, :noproc | :noconnect | :notransaction} when result: var
  def transaction(pool_mod, pool, timeout, fun) do
    ref = {__MODULE__, pool_mod, pool}
    case Process.get(ref) do
      nil ->
        transaction(pool_mod, pool, ref, timeout, fun)
      %{depth: 0} ->
        {:error, :notransaction}
      %{conn: _} = info ->
        do_transaction(ref, info, nil, fun)
      %{} ->
        {:error, :noconnect}
    end
  end

  @doc """
  Set the mode for the active transaction.

  ## Examples

      Pool.transaction(mod, pool, timeout,
        fn(ref, :raw, 1, _queue_time) ->
          :ok = Pool.mode(ref, :sandbox, timeout)
          Pool.transaction(mod, pool, timeout,
            fn(ref, :sandbox, 1, nil) -> :sandboxed end)
        end)

  """
  @spec mode(ref, mode, timeout) ::
    :ok | {:error, :already_mode | :noconnect}
  def mode({__MODULE__, _, _} = ref, mode, timeout) do
    case Process.get(ref) do
      %{conn: _ , mode: ^mode} ->
        {:error, :already_mode}
      %{conn: _} = info ->
        mode(ref, info, mode, timeout)
      %{} ->
        {:error, :noconnect}
    end
  end

  @doc """
  Get the connection module and pid for the active transaction or run.

  ## Examples

      Pool.transaction(mod, pool, timeout,
        fn(ref, :raw, 1, _queue_time) ->
          {:ok, {mod, conn}} = Pool.connection(ref)
        end)

  """
  @spec connection(ref) ::
    {:ok, conn} | {:error, :noconnect} when conn: {module, pid}
  def connection(ref) do
    case Process.get(ref) do
      %{conn: conn} ->
        {:ok, conn}
      %{} ->
        {:error, :noconnect}
    end
  end

  @doc """
  Break the active transaction or run.

  Calling `connection/1` inside the same transaction or run (at any depth) will
  return `{:error, :noconnect}`.

  ## Examples

      Pool.transaction(mod, pool, timout,
        fn(ref, :raw, 1, _queue_time) ->
          {:ok, {mod, conn}} = Pool.connection(ref)
          :ok = Pool.break(ref, timeout)
          {:error, :noconnect} = Pool.connection(ref)
        end)

      Pool.transaction(mod, pool, timeout,
        fn(ref, :raw, 1, _queue_time) ->
          :ok = Pool.break(ref, timeout)
          {:error, :noconnect} =
            Pool.transaction(mod, pool, timeout, fn(_, _, _, _) -> end)
        end)

  """
  @spec break(ref, timeout) :: :ok
  def break({__MODULE__, pool_mod, pool} = ref, timeout) do
    case Process.get(ref) do
      %{conn: _, worker: worker} = info ->
        _ = Process.put(ref, Map.delete(info, :conn))
        pool_mod.break(pool, worker, timeout)
      %{} ->
        :ok
    end
  end

  ## Helpers

  defp fuse(ref, timeout, fun, args) do
    try do
      apply(fun, args)
    catch
      class, reason ->
        stack = System.stacktrace()
        break(ref, timeout)
        :erlang.raise(class, reason, stack)
    end
  end

  defp run(pool_mod, pool, ref, timeout, fun) do
    case checkout(pool_mod, pool, timeout) do
      {:ok, %{conn: conn} = info, time} ->
        try do
          do_run(ref, conn, time, timeout, fun)
        after
          checkin(pool_mod, pool, info, timeout)
        end
      {:error, _} = error ->
        error
    end
  end

  defp do_run(ref, conn, time, timeout, fun) do
    {:ok, fuse(ref, timeout, fun, [conn, time])}
  end

  defp checkout(pool_mod, pool, timeout) do
    case pool_mod.checkout(pool, timeout) do
      {mode, worker, conn, time} when mode in [:raw, :sandbox] ->
        # We got permission to start a transaction
        {:ok, %{worker: worker, conn: conn, depth: 0, mode: mode}, time}
      {:error, reason} = error when reason in [:noproc, :noconnect] ->
        error
      {:error, err} ->
        raise err
    end
  end

  defp checkin(pool_mod, pool, %{conn: _, worker: worker}, timeout) do
    pool_mod.checkin(pool, worker, timeout)
  end
  defp checkin(_, _, %{}, _) do
    :ok
  end

  defp transaction(pool_mod, pool, ref, timeout, fun) do
    case open_transaction(pool_mod, pool, timeout) do
      {:ok, info, time} ->
        try do
          do_transaction(ref, info, time, fun)
        after
          info = Process.delete(ref)
          close_transaction(pool_mod, pool, info, timeout)
        end
      {:error, _} = error ->
        error
    end
  end

  defp do_transaction(ref, %{depth: depth, mode: mode, conn: conn} = info, time, fun) do
    depth = depth + 1
    _ = Process.put(ref, %{info | depth: depth})
    try do
      {:ok, fun.(ref, conn, mode, depth, time)}
    after
      case Process.put(ref, info) do
        %{conn: _} ->
          :ok
        %{} ->
          _ = Process.put(ref, Map.delete(info, :conn))
          :ok
      end
    end
  end

  defp open_transaction(pool_mod, pool, timeout) do
    case pool_mod.open_transaction(pool, timeout) do
      {mode, worker, conn, time} when mode in [:raw, :sandbox] ->
        # We got permission to start a transaction
        {:ok, %{worker: worker, conn: conn, depth: 0, mode: mode}, time}
      {:error, reason} = error when reason in [:noproc, :noconnect] ->
        error
      {:error, err} ->
        raise err
    end
  end

  defp close_transaction(pool_mod, pool, %{conn: _, worker: worker}, timeout) do
    pool_mod.close_transaction(pool, worker, timeout)
  end
  defp close_transaction(_, _, %{}, _) do
    :ok
  end

  defp mode(_, %{depth: 0}, _, _) do
    {:error, :notransaction}
  end
  defp mode({__MODULE__, pool_mod, pool} = ref, %{worker: worker} = info, mode, timeout) do
    put_mode = fn -> pool_mod.transaction_mode(pool, worker, mode, timeout) end
    case fuse(ref, timeout, put_mode, []) do
      :ok ->
        _ = Process.put(ref, %{info | mode: mode})
        :ok
      {:error, :noconnect} = error ->
        _ = Process.put(ref, Map.delete(info, :conn))
        error
    end
  end
end

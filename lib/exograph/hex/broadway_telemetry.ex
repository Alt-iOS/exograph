defmodule Exograph.Hex.BroadwayTelemetry do
  @moduledoc false

  alias Exograph.Hex.Progress

  @events [
    [:broadway, :processor, :stop],
    [:broadway, :batch_processor, :stop]
  ]

  def attach(pipeline_name) do
    id = {__MODULE__, pipeline_name, make_ref()}

    :telemetry.attach_many(id, @events, &__MODULE__.handle_event/4, %{
      pipeline_name: pipeline_name
    })

    id
  end

  def detach(id), do: :telemetry.detach(id)

  def handle_event([:broadway, :processor, :stop], measurements, metadata, %{
        pipeline_name: pipeline_name
      }) do
    if metadata.topology_name == pipeline_name do
      count =
        length(metadata.successful_messages_to_forward) +
          length(metadata.successful_messages_to_ack) + length(metadata.failed_messages)

      Progress.broadway_event(:processor, :default, count, measurements.duration)
    end
  end

  def handle_event([:broadway, :batch_processor, :stop], measurements, metadata, %{
        pipeline_name: pipeline_name
      }) do
    if metadata.topology_name == pipeline_name do
      shard_id = metadata.batch_info.batch_key
      count = length(metadata.successful_messages) + length(metadata.failed_messages)
      Progress.broadway_event(:batcher, shard_id, count, measurements.duration)
    end
  end
end

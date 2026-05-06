%{
  configs: [
    %{
      name: "default",
      checks: %{
        enabled: [
          {ExSlop, []}
        ],
        disabled: [
          {Credo.Check.Readability.ModuleDoc, []}
        ]
      }
    }
  ]
}

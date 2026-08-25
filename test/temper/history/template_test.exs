defmodule Temper.History.TemplateTest do
  use ExUnit.Case, async: true

  alias Temper.History.Template

  describe "expand/2" do
    test "replaces the placeholder with the partition value" do
      assert Template.expand("tmp/history-{partition}.jsonl", "3") == "tmp/history-3.jsonl"
    end

    test "a nil partition maps to 0, like the default path" do
      assert Template.expand("tmp/history-{partition}.jsonl", nil) == "tmp/history-0.jsonl"
    end

    test "a path without the placeholder passes through unchanged" do
      assert Template.expand("tmp/history.jsonl", "3") == "tmp/history.jsonl"
    end
  end

  describe "to_glob/1" do
    test "widens the placeholder to a wildcard" do
      assert Template.to_glob("tmp/history-{partition}.jsonl") == "tmp/history-*.jsonl"
    end

    test "a path without the placeholder passes through unchanged" do
      assert Template.to_glob("tmp/history.jsonl") == "tmp/history.jsonl"
    end
  end
end

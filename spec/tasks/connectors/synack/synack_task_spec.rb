# frozen_string_literal: true

require "rspec_helper"

RSpec.describe Kenna::Toolkit::SynackTask do
  subject(:task) { described_class.new }

  describe "#run" do
    let(:options) do
      {
        synack_api_host: 'api.synack.com',
        synack_api_token: 'abc123',
        kenna_api_key: 'api_key',
        kenna_api_host: 'kenna.example.com',
        kenna_connector_id: '12'
      }
    end
    let(:connector_run_success) { true }
    let(:kenna_client) do
      instance_double(
        Kenna::Api::Client,
        upload_to_connector: { 'data_file' => 12 },
        run_files_on_connector: { 'success' => connector_run_success },
        get_connector_runs: { results: [{ success: true, start_time: Time.now.to_s }] }
      )
    end

    before do
      stub_request(:get, "https://#{options[:synack_api_host]}/v1/vulnerabilities")
        .with(query: hash_including({}))
        .to_return do |request|
          page_number = WebMock::Util::QueryMapper.query_to_values(URI(request.uri).query)["page"]["number"]
          { body: read_fixture_file("response-#{page_number}.json") }
        end
      allow(Kenna::Api::Client).to receive(:new) { kenna_client }
      spy_on_accumulators
    end

    it 'succeeds' do
      expect { task.run(options) }.to_not raise_error
    end

    context 'when the required param is missed' do
      let(:options) { {} }

      it 'exits the script' do
        expect { task.run(options) }.to raise_error(SystemExit) { |e| expect(e.status).to_not be_zero }
      end
    end

    context 'when the API returns an error' do
      before do
        stub_request(:get, "https://#{options[:synack_api_host]}/v1/vulnerabilities")
          .with(query: hash_including({}))
          .to_return(status: [500, "Internal Server Error"])
        allow_any_instance_of(Object).to receive(:sleep) # Instant retries
      end

      it 'fails the task' do
        expect { task.run(options) }.to raise_error
      end
    end

    it 'creates assets with vulnerabilities' do
      task.run(options)
      expect(task.assets).to include(
        {
          "application" => "SYNACK-DEMO-W002",
          "ip_address" => "248.252.142.161",
          "tags" => [],
          "vulns" => [
            { "closed_at" => "2024-06-12-18:30:17",
              "created_at" => "2023-10-19-12:28:39",
              "last_seen_at" => Time.now.utc.strftime("%Y-%m-%d"),
              "scanner_identifier" => "synack-demo-w002-2",
              "scanner_score" => 6,
              "scanner_type" => "Synack",
              "status" => "closed",
              "vuln_def_name" =>
                "Insufficient Authorization Controls on Employee Document URLs" }
          ]
        }
      )
    end

    it 'creates vuln_defs' do
      task.run(options)
      expect(task.vuln_defs).to include(
        hash_including(
          "name" => "Insufficient Authorization Controls on Employee Document URLs",
          "scanner_identifier" => "synack-demo-w002-2",
          "scanner_type" => "Synack",
          "scanner_score" => 6,
          "description" =>
            a_string_including("There is an Insecure Direct Object Reference vulnerability due to"),
          "solution" =>
            a_string_including("The /api/empl_document/17/ endpoint should check that the user requesting a document")
        )
      )
    end

    describe 'vuln_defs details' do
      it 'sorts and concatenates validation steps' do
        task.run(options)
        # Steps 1-10 should be in numerical order, not alpha order like 1, 10, 11, 2...
        regex = Regexp.new((1..10).map { |n| "#{n}\\. .+" }.join("\\n"), Regexp::MULTILINE)
        expect(task.vuln_defs.first['details']).to match(regex)
      end
    end

    it 'creates the output file with the correct number of assets and vulnerabilities' do
      task.run(options)
      expect(File).to exist("output/synack/synack_batch_1.json")
      output = JSON.parse(File.read("output/synack/synack_batch_1.json"))
      assets = output['assets']
      expect(assets).to be_an(Array)
      expect(assets.size).to eq(46)
      expect(assets.sum { |asset| asset['vulns'].size }).to eq(48)
    end

    context 'when asset_defined_in_tag is true' do
      let(:options_with_asset_defined_in_tag) do
        options.merge(asset_defined_in_tag: true)
      end

      it 'uses it in the filter[search] query param for the API request' do
        task.run(options_with_asset_defined_in_tag)
        expect(a_request(:get, "https://#{options[:synack_api_host]}/v1/vulnerabilities")
          .with(query: hash_including("filter" => { "include_attachments" => "0", "search" => "kenna::" }))).to have_been_made.at_least_once
      end

      it 'selects only assets with the kenna::* tag' do
        task.run(options_with_asset_defined_in_tag)
        expect(task.assets).to all(include("tags" => []))
        expect(task.assets).to include(
          hash_including(
            "application" => "demo"
          )
        )
      end
    end
  end

  def spy_on_accumulators
    subject.extend Kenna::Toolkit::KdiAccumulatorSpy
  end

  def read_fixture_file(filename)
    File.read(File.join(%w[spec tasks connectors synack fixtures], filename))
  end
end

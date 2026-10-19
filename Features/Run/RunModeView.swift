import MapKit
import SwiftData
import SwiftUI

/// FIT-185: run mode. The map finds you, Start counts down 3-2-1, then the route draws as you go with the time,
/// miles, average pace, heart rate and each mile's split; Pause, then Resume or End, as Apple's Workout app does.
/// End shows the summary, which saves the run (with its route) or discards it. A run done elsewhere is logged by hand.
struct RunModeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var templates: [Template]
    let planned: PlannedActivity?

    @State private var recorder = RunRecorder()
    @State private var countdown: Int?
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var byHand = false
    @State private var kind = "easy"
    @State private var note = ""
    @State private var discarding = false

    var body: some View {
        Group {
            if recorder.phase == .ended { summary } else { live }
        }
        .task { await recorder.prepare() }
        .onAppear {
            if let planned, RunLogSheet.kinds.contains(planned.note.lowercased().prefix(while: \.isLetter).description) {
                kind = planned.note.lowercased().prefix(while: \.isLetter).description
            }
        }
        .onDisappear { recorder.close() }
        .sheet(isPresented: $byHand) {
            NavigationStack { RunLogSheet(planned: planned, templates: templates) { dismiss() } }
        }
    }

    // MARK: Running

    private var live: some View {
        VStack(spacing: 0) {
            map(follow: true)
                .overlay(alignment: .topLeading) {
                    if recorder.phase == .ready {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                                .background(.regularMaterial, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .padding(16)
                        .accessibilityLabel("Close")
                    }
                }
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(spacing: 18) {
                    Text(Running.clock(recorder.track.elapsed(at: timeline.date)))
                        .font(.system(size: 64, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(recorder.phase == .paused ? .secondary : .primary)
                    HStack {
                        stat(RunTrack.miles(recorder.track.meters), "mi")
                        stat(recorder.track.pace(at: timeline.date).map(Running.clock) ?? "–:––", "avg pace /mi")
                        if let bpm = recorder.heartRate { stat("\(Int(bpm.rounded()))", "bpm") }
                    }
                    if let split = recorder.track.splits.last {
                        Text("Mile \(recorder.track.splits.count) in \(Running.clock(split))").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 24)
            Spacer(minLength: 16)
            controls.padding(.bottom, 24)
        }
        .overlay {
            if let countdown {
                Text("\(countdown)").font(.system(size: 120, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial)
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .alert("Location is off", isPresented: Binding(get: { recorder.locationDenied && recorder.phase == .ready }, set: { _ in })) {
            Button("Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
            Button("Log by Hand") { byHand = true }
        } message: { Text("Run mode needs your location to map the run and measure it.") }
    }

    @ViewBuilder private var controls: some View {
        switch recorder.phase {
        case .ready:
            VStack(spacing: 14) {
                Button(action: begin) {
                    Text("Start").font(.title2.weight(.semibold)).frame(width: 120, height: 120)
                        .foregroundStyle(Color(.systemBackground)).background(Color.primary, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(countdown != nil)
                Button("Log It by Hand") { byHand = true }.font(.subheadline).tint(.secondary)
            }
        case .running:
            round("pause.fill", "Pause") { recorder.pause() }
        case .paused:
            HStack(spacing: 40) {
                round("stop.fill", "End") { recorder.end() }
                round("play.fill", "Resume") { recorder.resume() }
            }
        case .ended:
            EmptyView()
        }
    }

    private func round(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title).frame(width: 84, height: 84)
                    .foregroundStyle(Color(.systemBackground)).background(Color.primary, in: .circle)
                Text(title).font(.subheadline.weight(.medium))
            }
        }
        .buttonStyle(.plain)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func begin() {
        Task {
            for n in [3, 2, 1] {
                withAnimation { countdown = n }
                try? await Task.sleep(for: .seconds(1))
            }
            countdown = nil
            await recorder.start()
        }
    }

    // MARK: The map

    private var route: [CLLocationCoordinate2D] {
        recorder.track.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private func map(follow: Bool) -> some View {
        Map(position: follow ? $camera : .constant(.automatic)) {
            if follow { UserAnnotation() }
            if route.count > 1 { MapPolyline(coordinates: route).stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)) }
        }
        .mapControls { if follow { MapUserLocationButton() } }
    }

    // MARK: The summary

    private var summary: some View {
        NavigationStack {
            Form {
                Section {
                    RouteMap(points: recorder.track.points).frame(height: 240).listRowInsets(EdgeInsets())
                }
                Section {
                    LabeledContent("Distance", value: "\(RunTrack.miles(recorder.track.meters)) mi")
                    LabeledContent("Time", value: Running.clock(seconds))
                    if let pace = recorder.track.pace(at: recorder.ended ?? .now) { LabeledContent("Avg pace", value: "\(Running.clock(pace)) /mi") }
                    if let bpm = recorder.averageHeartRate { LabeledContent("Avg heart rate", value: "\(Int(bpm.rounded())) bpm") }
                }
                if !recorder.track.splits.isEmpty {
                    Section("Splits") {
                        ForEach(Array(recorder.track.splits.enumerated()), id: \.offset) { index, split in
                            LabeledContent("Mile \(index + 1)", value: Running.clock(split)).monospacedDigit()
                        }
                    }
                }
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(RunLogSheet.kinds, id: \.self) { Text($0.capitalized) }
                    }
                    TextField("How it felt", text: $note, axis: .vertical)
                }
            }
            .navigationTitle("Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Discard", role: .destructive) { discarding = true } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(recorder.track.meters < 10) }
            }
            .confirmationDialog("Discard this run?", isPresented: $discarding, titleVisibility: .visible) {
                Button("Discard Run", role: .destructive) {
                    recorder.discard()
                    dismiss()
                }
            }
        }
    }

    private var seconds: Double { recorder.track.elapsed(at: recorder.ended ?? .now).rounded() }

    private func save() {
        var measurements = [Measurement(metric: "distance_m", value: recorder.track.meters.rounded(), unit: "m"),
                            Measurement(metric: "duration_s", value: seconds, unit: "s")]
        if let bpm = recorder.averageHeartRate { measurements.append(Measurement(metric: "hr_avg", value: bpm.rounded(), unit: "bpm")) }
        // FIT-188: each mile's split, in order, so the run's page shows them later.
        measurements += recorder.track.splits.map { Measurement(metric: "split_s", value: $0.rounded(), unit: "s") }
        let said = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = LogEntry(kind: .workout, timestamp: recorder.track.started ?? .now, plannedRef: planned?.id,
                             templateRef: templates.first { $0.slug == Running.outdoor }?.id, measurements: measurements,
                             note: said.isEmpty ? kind : "\(kind): \(said)")
        entry.route = Polyline.encode(recorder.track.points)
        context.insert(entry)
        try? context.save()
        Task { await recorder.saveWorkout() }
        dismiss()
    }
}

/// A logged run's route, framed to fit: a picture of where the run went, or a map to explore on the run's page.
struct RouteMap: View {
    let points: [Polyline.Point]
    /// FIT-188: the run's own page lets you move around the map.
    var interactive = false

    var body: some View {
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        Map(initialPosition: .automatic, interactionModes: interactive ? .all : []) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates).stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let first = coordinates.first { Annotation("Start", coordinate: first) { Circle().fill(.green).frame(width: 10, height: 10) }.annotationTitles(.hidden) }
            if let last = coordinates.last, coordinates.count > 1 { Annotation("End", coordinate: last) { Circle().fill(.red).frame(width: 10, height: 10) }.annotationTitles(.hidden) }
        }
    }
}

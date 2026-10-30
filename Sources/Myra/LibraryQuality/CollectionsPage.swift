import SwiftUI

/// Collections: smart collections that update themselves with the library. Pin the ones to show
/// on Home. Opening one shows its titles as the usual poster grid.
struct CollectionsPage: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var store: EntertainmentStore
  @Binding var pageAction: ShellPageAction?

  @State private var editing: SmartCollection?
  @State private var opened: SmartCollection?

  var body: some View {
    Group {
      if let opened {
        openedCollection(opened)
      } else {
        overview
      }
    }
    .onChange(of: pageAction) { _, action in
      guard action == .newCollection else { return }
      pageAction = nil
      editing = SmartCollection(name: "My collection", rules: [SmartRule(field: .quality, value: "2160p")])
    }
    .sheet(item: $editing) { collection in
      SmartRuleBuilderView(
        store: store, original: collection, isNew: !store.smartCollections.contains { $0.id == collection.id }
      ) {
        editing = nil
      }
    }
  }

  private var overview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Smart collections update themselves whenever the library changes. Pin the ones you like to Home.")
          .font(.system(size: 12)).foregroundStyle(MyraColor.text2)
          .padding(.top, 14)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)], spacing: 12) {
          ForEach(store.smartCollections) { collection in
            CollectionCard(
              collection: collection,
              count: SmartCollectionRules.count(
                matching: collection.rules, in: store.catalogue, watched: store.personal.watched),
              open: { opened = collection },
              edit: { editing = collection },
              togglePinned: { store.setSmartCollectionPinned(id: collection.id, !collection.pinnedToHome) },
              delete: { store.deleteSmartCollection(id: collection.id) })
          }
          Button {
            editing = SmartCollection(name: "My collection", rules: [SmartRule(field: .quality, value: "2160p")])
          } label: {
            Label("New Collection", systemImage: "plus")
              .frame(maxWidth: .infinity, minHeight: 110)
              .foregroundStyle(MyraColor.text2)
              .overlay(
                RoundedRectangle(cornerRadius: 10)
                  .strokeBorder(MyraColor.line, style: StrokeStyle(lineWidth: 1, dash: [4]))
              )
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, HomeLayout.pageInset)
      .padding(.bottom, 30)
    }
  }

  private func openedCollection(_ collection: SmartCollection) -> some View {
    let matches = SmartCollectionRules.titles(
      matching: collection.rules, in: store.catalogue, watched: store.personal.watched)
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Button {
          opened = nil
        } label: {
          Label("Collections", systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        .foregroundStyle(MyraColor.text2)
        Text(collection.name).font(.system(size: 17, weight: .bold))
        Text(matches.count.formatted()).foregroundStyle(MyraColor.text3).monospacedDigit()
        Spacer()
      }
      .padding(.top, 14)
      .padding(.horizontal, HomeLayout.pageInset)
      Text(SmartCollectionRules.summary(collection.rules))
        .font(.system(size: 12)).foregroundStyle(MyraColor.text2)
        .padding(.horizontal, HomeLayout.pageInset)
        .padding(.bottom, 8)
      CollectionTitleGrid(coordinator: coordinator, store: store, titles: matches)
    }
  }
}

private struct CollectionCard: View {
  let collection: SmartCollection
  let count: Int
  let open: () -> Void
  let edit: () -> Void
  let togglePinned: () -> Void
  let delete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(collection.name).font(.system(size: 14, weight: .semibold))
        Text(count.formatted()).font(.system(size: 12)).foregroundStyle(MyraColor.text3).monospacedDigit()
        Spacer()
        if collection.pinnedToHome {
          Image(systemName: "pin.fill").foregroundStyle(MyraColor.text2)
            .accessibilityLabel("Shown on Home")
        }
      }
      Text(SmartCollectionRules.summary(collection.rules))
        .font(.system(size: 11)).foregroundStyle(MyraColor.text2)
        .lineLimit(2)
      HStack(spacing: 6) {
        Button("Open", action: open).buttonStyle(MyraButtonStyle(prominent: true))
        Button("Edit", action: edit).buttonStyle(MyraButtonStyle())
        Button(collection.pinnedToHome ? "Unpin" : "Pin to Home", action: togglePinned)
          .buttonStyle(MyraButtonStyle())
        Spacer()
        Menu {
          Button("Delete Collection", role: .destructive, action: delete)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(MyraColor.content, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(MyraColor.line, lineWidth: 1))
  }
}

/// The matching titles as a poster grid, with the same play and details actions as the other pages.
private struct CollectionTitleGrid: View {
  @ObservedObject var coordinator: AppCoordinator
  @ObservedObject var store: EntertainmentStore
  let titles: [EntertainmentTitle]

  @AppStorage(TitleGridLayout.cellKey) private var cell = TitleGridLayout.defaultCell

  var body: some View {
    TitleBrowserHost(coordinator: coordinator, store: store) { actions in
      ScrollView {
        if titles.isEmpty {
          ContentUnavailableView(
            "No titles match yet", systemImage: "line.3.horizontal.decrease.circle",
            description: Text("Titles appear here when they match every rule."))
            .frame(minHeight: 280)
        } else {
          TitleGrid(titles: titles, store: store, cell: CGFloat(cell), actions: actions)
            .padding(.horizontal, HomeLayout.pageInset - TitleGridLayout.ringInset)
        }
      }
    }
  }
}

/// The rule builder: a name, rows of field, operator and value, a live count and Save.
struct SmartRuleBuilderView: View {
  @ObservedObject var store: EntertainmentStore
  let original: SmartCollection
  let isNew: Bool
  let done: () -> Void

  @State private var name: String
  @State private var rules: [SmartRule]
  @State private var pinned: Bool
  @State private var matchCount: Int?
  @State private var message: String?

  init(store: EntertainmentStore, original: SmartCollection, isNew: Bool, done: @escaping () -> Void) {
    self.store = store
    self.original = original
    self.isNew = isNew
    self.done = done
    _name = State(initialValue: original.name)
    _rules = State(initialValue: original.rules.isEmpty ? [SmartRule(field: .kind, value: "movie")] : original.rules)
    _pinned = State(initialValue: original.pinnedToHome)
  }

  private var draft: SmartCollection {
    SmartCollection(id: original.id, name: name, rules: rules, pinnedToHome: pinned)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(isNew ? "New smart collection" : "Edit smart collection").font(.title2.bold())
      Text("Updates itself whenever the library changes.")
        .font(.caption).foregroundStyle(.secondary)
      TextField("Name", text: $name)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Collection name")
      Text("Include titles where…").font(.callout).foregroundStyle(.secondary)
      ForEach(rules.indices, id: \.self) { index in
        ruleRow(index)
      }
      HStack {
        Button {
          rules.append(SmartRule(field: .watched, value: "no"))
        } label: {
          Label("Add a rule", systemImage: "plus")
        }
        .disabled(rules.count >= SmartCollectionRules.maximumRules)
        Spacer()
      }
      Toggle("Show on Home", isOn: $pinned)
      HStack {
        Text(countText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        Spacer()
      }
      if let message {
        Text(message).font(.caption).foregroundStyle(.orange)
      }
      HStack {
        Button("Cancel", action: done).keyboardShortcut(.cancelAction)
        Spacer()
        Button("Save Collection") {
          if store.saveSmartCollection(draft) {
            done()
          } else {
            message = "Give the collection a name and a complete rule for each row."
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!SmartCollectionRules.isValid(draft))
      }
    }
    .padding(24)
    .frame(width: 580)
    .task(id: rules) {
      let snapshot = store.catalogue
      let watched = store.personal.watched
      let current = rules
      matchCount = await Task.detached(priority: .userInitiated) {
        SmartCollectionRules.count(matching: current, in: snapshot, watched: watched)
      }.value
    }
  }

  private var countText: String {
    guard SmartCollectionRules.isValid(draft) else { return "Complete every row to see the count." }
    guard let matchCount else { return "Counting…" }
    return "\(matchCount.formatted()) titles match now"
  }

  @ViewBuilder private func ruleRow(_ index: Int) -> some View {
    HStack(spacing: 8) {
      Picker("Field", selection: fieldBinding(index)) {
        ForEach(SmartField.allCases) { Text($0.title).tag($0) }
      }
      .labelsHidden()
      .frame(width: 130)
      Picker("Operator", selection: operatorBinding(index)) {
        ForEach(rules[index].field.operators) { Text($0.title).tag($0) }
      }
      .labelsHidden()
      .frame(width: 170)
      valueControl(index)
      Button {
        rules.remove(at: index)
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .disabled(rules.count <= 1)
      .accessibilityLabel("Remove rule")
    }
  }

  @ViewBuilder private func valueControl(_ index: Int) -> some View {
    let field = rules[index].field
    if field.fixedValues.isEmpty {
      TextField(field == .genre ? "Genre, such as Drama" : "Language code, such as en", text: valueBinding(index))
        .textFieldStyle(.roundedBorder)
        .frame(width: 170)
    } else {
      Picker("Value", selection: valueBinding(index)) {
        ForEach(field.fixedValues, id: \.self) { value in
          Text(Self.label(field: field, value: value)).tag(value)
        }
      }
      .labelsHidden()
      .frame(width: 170)
    }
  }

  static func label(field: SmartField, value: String) -> String {
    switch field {
    case .kind: value == "series" ? "Series" : "Movie"
    case .watched: value == "yes" ? "Yes" : "No"
    case .runtime: "\(value) min"
    case .rating: "\(value)+"
    case .added: value == "7" ? "Last 7 days" : "Last \(value) days"
    default: value
    }
  }

  private func fieldBinding(_ index: Int) -> Binding<SmartField> {
    Binding(
      get: { rules[index].field },
      set: { newField in
        rules[index] = SmartRule(field: newField, value: newField.fixedValues.first ?? "")
      })
  }

  private func operatorBinding(_ index: Int) -> Binding<SmartOperator> {
    Binding(
      get: { rules[index].op },
      set: { rules[index].op = $0 })
  }

  private func valueBinding(_ index: Int) -> Binding<String> {
    Binding(
      get: { rules[index].value },
      set: { rules[index].value = $0 })
  }
}

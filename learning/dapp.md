Here’s the revised prompt with that requirement built in clearly:

---

# Feature Addition Prompt (Existing App)

## Role

Senior .NET Developer

## Objective

Add a **Release Management feature** to an **existing Blazor Web App (C#)**.

Use the app’s **current architecture, folder structure, patterns, naming conventions, dependency injection setup, shared components, and existing Azure Cosmos DB integration**.

Do **not** treat this as a greenfield project.
Do **not** introduce a new architecture.
The implementation must fit naturally into the current codebase.

---

## Key Instruction

Before creating the feature, first review and follow the **existing project architecture**.

This includes:

* current folder organization
* page/component structure
* service layer patterns
* repository/data-access patterns
* model conventions
* dependency injection style
* routing conventions
* navigation/menu structure
* existing Cosmos DB usage
* existing UI/layout/styling conventions
* shared components and reusable patterns

When adding this feature:

* reuse existing patterns wherever possible
* extend the app in the same style as the rest of the project
* avoid unnecessary abstractions or duplicate infrastructure
* do not add parallel patterns if the app already has a preferred way to do things

If the app already has an established architecture for CRUD pages, services, or Cosmos DB access, follow that architecture for the Release feature.

---

## Requirements

### 1. Data Model (`Release.cs`)

Add a new model in the appropriate existing location, following the project’s current model conventions.

Fields:

* `id` (string / Guid)
* `Summary`
* `Issues`
* `ReleaseExceptions`
* `ReleaseNotes`
* `PublishChecklist`
* `ProjectChecklist`
* `DevOpsActivities`
* `ReleaseProcessChecklist`
* `List<string> WorkItems`

Use the same naming, serialization, and validation style already used in the project.

---

### 2. New Pages

## A. Release Dashboard (`/releases`)

Create the releases list page using the project’s existing page/component pattern.

### UI Requirements

* Button: **Add Release**
* Search input: filter by `Summary`
* Table listing releases from Cosmos DB

### Table Columns

* Summary
* Issues (truncated)
* Release Notes (truncated)
* WorkItems count
* Actions

### Actions Column

For each release, include:

* **View** link/button → `/releases/{id}`
* **Edit** link/button → `/releases/edit/{id}`

Use the same table, button, and navigation style already used elsewhere in the app.

---

## B. View Release Page (`/releases/{id}`)

Create a read-only page for a single release.

### Display

Show all fields:

* Summary
* Issues
* ReleaseExceptions
* ReleaseNotes
* PublishChecklist
* ProjectChecklist
* DevOpsActivities
* ReleaseProcessChecklist
* WorkItems list

### Actions

* **Edit Release** → `/releases/edit/{id}`
* **Back** → `/releases`

Use existing read-only/detail page conventions if they exist.

---

## C. Add Release Page (`/releases/add`)

Create a page for adding a release.

### Layout

* Left sidebar navigation using Bootstrap `nav-pills flex-column` if consistent with the current UI
* Right side form content

### Tabs and Fields

#### Summary

* `InputTextArea`

#### Release Issues

* `InputTextArea` for:

  * Issues
  * ReleaseExceptions
  * ReleaseNotes

#### Work Items

* Add Work Item button
* Add a new item to `WorkItems`
* Render an input for each item
* Allow removal

#### Checklist Tabs

* PublishChecklist
* ProjectChecklist
* DevOpsActivities
* ReleaseProcessChecklist

Each uses `InputTextArea`

### Actions

* Save → create release
* Cancel → navigate back to `/releases`

---

## D. Edit Release Page (`/releases/edit/{id}`)

Create an edit page for an existing release.

### Requirements

* Same form structure as Add Release
* Load existing release data
* Pre-populate all fields
* Save updates back to Cosmos DB

### Actions

* Save → update release
* Cancel → navigate back to `/releases`

Use the same editing pattern already used elsewhere in the application.

---

## 3. Service / Data Access Layer

Implement the feature using the project’s **existing Cosmos DB architecture**.

### Important Rules

* Reuse the app’s current Cosmos DB client/configuration
* Do not add Cosmos DB Emulator logic
* Do not create a second or parallel Cosmos DB infrastructure
* Do not introduce a new repository/service pattern unless the app already uses it
* Follow the existing data-access approach exactly

### Required Operations

Add support for:

* `GetReleasesAsync(filter)`
* `GetReleaseAsync(id)`
* `AddReleaseAsync(release)`
* `UpdateReleaseAsync(release)`

### Data Access Behavior

* Use the existing database/container strategy already used by the app
* Match the current partition key strategy
* Match the current query and persistence style
* Support filtering by `Summary`

---

## 4. Dependency Injection

Only register new services if needed, and do it using the project’s current DI style.

Do not change service lifetimes or registration patterns unless required by the existing architecture.

---

## 5. Navigation and Integration

Integrate the feature into the current app naturally.

### Requirements

* Add a navigation/menu link to `/releases`
* Reuse existing layouts, components, and styling
* Keep naming and routing consistent with the rest of the app
* Do not break existing features
* Do not refactor unrelated areas unless required for clean integration

---

## 6. Constraints

* Do not use Cosmos DB Emulator
* Do not add new database configuration unless absolutely required by the existing architecture
* Do not invent a new structure separate from the current app
* Keep the implementation maintainable, minimal, and consistent with the codebase

---

## 7. Output Expectation

Provide only:

* new files
* modified files
* any required route/navigation updates

When generating the code:

* base it on the current architecture of the project
* explain any assumptions about the existing structure
* keep changes minimal and well-integrated
* do not output boilerplate that duplicates what the app already has

---

## Final Instruction

Before writing code, inspect the current project structure and infer how features are currently organized. Then implement the Release feature in the same architectural style.

---

I can also make this even stronger as a **code-generation prompt that explicitly tells the AI to inspect existing folders and mirror current CRUD/service patterns before producing files**.

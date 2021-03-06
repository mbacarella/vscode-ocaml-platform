open Import

(* Terminology:
   - Package_manager: represents supported package managers
     with Global as the fallback
   - project_root is different from Package_manager root (Eg. Opam
     (Path.of_string "/foo/bar")). Project root
     is the directory where manifest file (opam/esy.json/package.json)
     was found. Package_manager root is the directory that contains the
     manifest file responsible for setting up the toolchain - the two
     are same for Esy and Opam project but different for
     bucklescript. Bucklescript projects have this manifest file
     abstracted away from the user (at least at the moment)
   - Manifest: abstracts functions handling manifest files
     of the supported package managers *)

module Package_manager = struct
  module Kind = struct
    type t =
      | Opam
      | Esy
      | Global
      | Custom

    module Hmap = struct
      type ('opam, 'esy, 'global, 'custom) t =
        { opam : 'opam
        ; esy : 'esy
        ; global : 'global
        ; custom : 'custom
        }
    end

    let of_string = function
      | "opam" -> Some Opam
      | "esy" -> Some Esy
      | "global" -> Some Global
      | "custom" -> Some Custom
      | _ -> None

    let of_json json =
      let open Jsonoo.Decode in
      match of_string (string json) with
      | Some s -> s
      | None ->
        raise
          (Jsonoo.Decode_error
             "opam | esy | global | custom are the only valid values")

    let to_string = function
      | Opam -> "opam"
      | Esy -> "esy"
      | Global -> "global"
      | Custom -> "custom"

    let to_json s = Jsonoo.Encode.string (to_string s)
  end

  type t =
    | Opam of Opam.t * Opam.Switch.t
    | Esy of Esy.t * Path.t
    | Global
    | Custom of string

  module Setting = struct
    type t =
      | Opam of Opam.Switch.t
      | Esy of Path.t
      | Global
      | Custom of string

    let kind : t -> Kind.t = function
      | Opam _ -> Opam
      | Esy _ -> Esy
      | Global -> Global
      | Custom _ -> Custom

    let of_json json =
      let open Jsonoo.Decode in
      let kind = field "kind" Kind.of_json json in
      match (kind : Kind.t) with
      | Global -> Global
      | Esy ->
        let manifest =
          field "root" (fun js -> Path.of_string (string js)) json
        in
        Esy manifest
      | Opam ->
        let switch =
          field "switch" (fun js -> Opam.Switch.make (string js)) json
        in
        Opam switch
      | Custom ->
        let template = field "template" string json in
        Custom template

    let to_json (t : t) =
      let open Jsonoo.Encode in
      let kind = ("kind", Kind.to_json (kind t)) in
      match t with
      | Global -> Jsonoo.Encode.object_ [ kind ]
      | Esy manifest ->
        object_ [ kind; ("root", string @@ Path.to_string manifest) ]
      | Opam sw -> object_ [ kind; ("switch", string @@ Opam.Switch.name sw) ]
      | Custom template -> object_ [ kind; ("template", string template) ]

    let t = Settings.create ~scope:Workspace ~key:"sandbox" ~of_json ~to_json
  end

  let to_setting = function
    | Esy (_, root) -> Setting.Esy root
    | Opam (_, switch) -> Setting.Opam switch
    | Global -> Setting.Global
    | Custom template -> Setting.Custom template

  let to_string = function
    | Esy (_, root) -> Printf.sprintf "esy(%s)" (Path.to_string root)
    | Opam (_, switch) -> Printf.sprintf "opam(%s)" (Opam.Switch.name switch)
    | Global -> "global"
    | Custom _ -> "custom"

  let to_pretty_string t =
    let print_opam = Printf.sprintf "opam(%s)" in
    let print_esy = Printf.sprintf "esy(%s)" in
    match t with
    | Esy (_, root) ->
      let project_name = Path.basename root in
      print_esy project_name
    | Opam (_, Named name) -> print_opam name
    | Opam (_, Local path) ->
      let project_name = Path.basename path in
      print_opam project_name
    | Global -> "Global OCaml"
    | Custom _ -> "Custom OCaml"
end

type resources = Package_manager.t

let package_manager (t : resources) : Package_manager.t = t

let available_package_managers () =
  { Package_manager.Kind.Hmap.opam = Opam.make ()
  ; esy = Esy.make ()
  ; global = ()
  ; custom = ()
  }

let of_settings () : Package_manager.t option Promise.t =
  let open Promise.Syntax in
  let available = available_package_managers () in
  let not_available kind =
    let this_ =
      match kind with
      | `Esy -> "esy"
      | `Opam -> "opam"
    in
    message `Warn
      "This workspace is configured to use an %s sandbox, but %s isn't \
       available"
      this_ this_
  in
  match
    ( Settings.get ~section:"ocaml" Package_manager.Setting.t
      : Package_manager.Setting.t option )
  with
  | None -> Promise.return None
  | Some (Esy manifest) -> (
    available.esy >>| function
    | None ->
      not_available `Esy;
      None
    | Some esy -> Some (Package_manager.Esy (esy, manifest)) )
  | Some (Opam switch) -> (
    let open Promise.Syntax in
    available.opam >>= function
    | None ->
      not_available `Opam;
      Promise.return None
    | Some opam -> (
      Opam.exists opam ~switch >>| function
      | false ->
        message `Warn
          "Workspace is configured to use the switch %s. This switch does not \
           exist."
          (Opam.Switch.name switch);
        None
      | true -> Some (Package_manager.Opam (opam, switch)) ) )
  | Some Global -> Promise.return (Some Package_manager.Global)
  | Some (Custom template) ->
    Promise.return (Some (Package_manager.Custom template))

let to_settings (pm : Package_manager.t) =
  Settings.set ~section:"ocaml" Package_manager.Setting.t
    (Package_manager.to_setting pm)

module Candidate = struct
  type t =
    { package_manager : Package_manager.t
    ; status : (unit, string) result
    }

  let to_quick_pick { package_manager; status } =
    let create = QuickPickItem.create in
    let description =
      match status with
      | Error s -> Some (Printf.sprintf "invalid: %s" s)
      | Ok () -> (
        match package_manager with
        | Opam (_, Local _) -> Some "Local switch"
        | Opam (_, Named _) -> Some "Global switch"
        | _ -> None )
    in
    match package_manager with
    | Package_manager.Opam (_, Named name) -> create ~label:name ?description ()
    | Opam (_, Local path) ->
      let project_name = Path.basename path in
      let project_path = Path.to_string path in
      create ~label:project_name ~detail:project_path ?description ()
    | Esy (_, p) ->
      let project_name = Path.basename p in
      let project_path = Path.to_string p in
      create ~detail:project_path ~label:project_name ~description:"Esy" ()
    | Global ->
      create ~label:"Global" ?description
        ~detail:"Global toolchain inherited from the environment" ()
    | Custom _ ->
      create ?description ~label:"Custom"
        ~detail:"Custom toolchain using a command template" ()

  let ok package_manager = { package_manager; status = Ok () }
end

let select_package_manager (choices : Candidate.t list) =
  let placeHolder =
    "Which package manager would you like to manage the toolchain?"
  in
  let choices =
    List.map
      ~f:(fun (pm : Candidate.t) ->
        let quick_pick = Candidate.to_quick_pick pm in
        (quick_pick, pm))
      choices
  in
  let options = QuickPickOptions.create ~canPickMany:false ~placeHolder () in
  Window.showQuickPickItems ~choices ~options ()

let sandbox_candidates ~workspace_folders =
  let open Promise.Syntax in
  let available = available_package_managers () in
  let esy =
    available.esy >>= function
    | None -> Promise.return []
    | Some esy ->
      workspace_folders
      |> List.map ~f:(fun (folder : WorkspaceFolder.t) ->
             let dir =
               folder |> WorkspaceFolder.uri |> Uri.fsPath |> Path.of_string
             in
             Esy.discover ~dir)
      |> Promise.all_list
      >>| fun esys ->
      esys |> List.concat
      |> List.map ~f:(fun (manifest : Esy.discover) ->
             { Candidate.package_manager =
                 Package_manager.Esy (esy, manifest.file)
             ; status = manifest.status
             })
  in
  let opam =
    available.opam >>= function
    | None -> Promise.return []
    | Some opam ->
      Opam.switch_list opam
      >>| List.map ~f:(fun sw ->
              let package_manager = Package_manager.Opam (opam, sw) in
              { Candidate.package_manager; status = Ok () })
  in
  let global = Candidate.ok Package_manager.Global in
  let custom =
    Candidate.ok (Package_manager.Custom "$prog $args")
    (* doesn't matter what the custom fields are set to here
       user will input custom commands in [select] *)
  in

  Promise.all2 (esy, opam) >>| fun (esy, opam) ->
  (global :: custom :: esy) @ opam

let setup_toolchain (kind : Package_manager.t) =
  match kind with
  | Esy (esy, manifest) -> Esy.setup_toolchain esy ~manifest
  | Opam _
  | Global
  | Custom _ ->
    Promise.Result.return ()

let make_resources kind = kind

let select () =
  let open Promise.Syntax in
  let workspace_folders = Workspace.workspaceFolders () in
  sandbox_candidates ~workspace_folders >>= fun candidates ->
  let open Promise.Option.Syntax in
  select_package_manager candidates >>= function
  | { status = Ok (); package_manager = Custom _ } ->
    let validateInput ~value =
      if
        String.is_substring value ~substring:"$prog"
        && String.is_substring value ~substring:"$args"
      then
        Promise.return None
      else
        Promise.Option.return "Command template must include $prog and $args"
    in
    let options =
      InputBoxOptions.create ~prompt:"Input a custom command template"
        ~value:"$prog $args" ~validateInput ()
    in
    Window.showInputBox ~options () >>| String.strip >>= fun template ->
    Promise.Option.return @@ Package_manager.Custom template
  | { status; package_manager } -> (
    match status with
    | Error s ->
      message `Warn "This toolchain is invalid. Error: %s" s;
      Promise.return None
    | Ok () -> Promise.Option.return package_manager )

let select_and_save () =
  let open Promise.Option.Syntax in
  select () >>= fun package_manager ->
  let open Promise.Syntax in
  to_settings package_manager >>| fun () -> Some package_manager

let get_command (t : Package_manager.t) bin args : Cmd.t =
  match t with
  | Opam (opam, switch) -> Opam.exec opam ~switch ~args:(bin :: args)
  | Esy (esy, manifest) -> Esy.exec esy ~manifest ~args:(bin :: args)
  | Global -> Spawn { bin = Path.of_string bin; args }
  | Custom template ->
    let bin =
      if String.contains bin ' ' then
        "\"" ^ bin ^ "\""
      else
        bin
    in
    let command =
      template
      |> String.substr_replace_all ~pattern:"$prog" ~with_:bin
      |> String.substr_replace_all ~pattern:"$args"
           ~with_:(String.concat ~sep:" " args)
      |> String.strip
    in
    Shell command

let get_lsp_command ?(args = []) (t : Package_manager.t) : Cmd.t =
  get_command t "ocamllsp" args

let get_dune_command (t : Package_manager.t) args : Cmd.t =
  get_command t "dune" args

let run_setup resources =
  let open Promise.Result.Syntax in
  setup_toolchain resources
  >>= (fun () ->
        let args = [ "--version" ] in
        let command = get_lsp_command resources ~args in
        Cmd.check command >>= fun cmd -> Cmd.output cmd)
  |> Promise.map (function
       | Ok _ -> Ok ()
       | Error msg ->
         Error (Printf.sprintf "Toolchain initialisation failed: %s" msg))

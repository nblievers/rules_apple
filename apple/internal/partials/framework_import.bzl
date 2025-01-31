# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Partial implementation for framework import file processing."""

load(
    "@build_bazel_rules_apple//apple/internal:apple_framework_import.bzl",
    "AppleFrameworkImportInfo",
)
load(
    "@build_bazel_rules_apple//apple/internal:processor.bzl",
    "processor",
)
load(
    "@build_bazel_rules_apple//apple/internal/utils:bundle_paths.bzl",
    "bundle_paths",
)
load(
    "@build_bazel_rules_apple//apple/internal:intermediates.bzl",
    "intermediates",
)
load(
    "@build_bazel_rules_apple//apple/internal:outputs.bzl",
    "outputs",
)
load(
    "@bazel_skylib//lib:partial.bzl",
    "partial",
)
load(
    "@bazel_skylib//lib:paths.bzl",
    "paths",
)

def _framework_import_partial_impl(ctx, targets, targets_to_avoid, extra_binaries):
    """Implementation for the framework import file processing partial."""
    _ignored = [ctx]

    transitive_sets = [
        x[AppleFrameworkImportInfo].framework_imports
        for x in targets
        if AppleFrameworkImportInfo in x
    ]
    files_to_bundle = depset(transitive = transitive_sets).to_list()

    if targets_to_avoid:
        avoid_transitive_sets = [
            x[AppleFrameworkImportInfo].framework_imports
            for x in targets_to_avoid
            if AppleFrameworkImportInfo in x
        ]
        if avoid_transitive_sets:
            avoid_files = depset(transitive = avoid_transitive_sets).to_list()

            # Remove any files present in the targets to avoid from framework files that need to be
            # bundled.
            files_to_bundle = [x for x in files_to_bundle if x not in avoid_files]

    bundle_files = []
    slicer_args = []
    main_binary = outputs.binary(ctx)
    for file in files_to_bundle:
        framework_path = bundle_paths.farthest_parent(file.short_path, "framework")
        framework_relative_path = paths.relativize(file.short_path, framework_path)

        parent_dir = paths.basename(framework_path)
        framework_relative_dir = paths.dirname(framework_relative_path).strip("/")
        if framework_relative_dir:
            parent_dir = paths.join(parent_dir, framework_relative_dir)

        # check to see if the the parent is "Foo.[extension]" and the file is "Foo", thus "Foo.framework/Foo", so the binary within the framework.
        if paths.replace_extension(parent_dir, "") == file.basename:
            stripped = intermediates.file(
                ctx.actions,
                ctx.label.name,
                paths.join("_imported_frameworks", file.basename),
            )
            bundle_files.append(
                (processor.location.framework, parent_dir, depset([stripped])),
            )

            args = slicer_args + ["--in", file.path, "--out", stripped.path]
            all_binaries = extra_binaries + [main_binary]
            for binary in all_binaries:
                args.append(binary.path)

            ctx.actions.run(
                inputs = [file] + all_binaries,
                tools = [ctx.executable._realpath],
                executable = ctx.executable._dynamic_framework_slicer,
                outputs = [stripped],
                arguments = args,
                mnemonic = "DynamicFrameworkSlicer",
            )
        else:
            bundle_files.append(
                (processor.location.framework, parent_dir, depset([file])),
            )

    return struct(bundle_files = bundle_files)

def framework_import_partial(targets, targets_to_avoid = [], extra_binaries = []):
    """Constructor for the framework import file processing partial.

    This partial propagates framework import file bundle locations. The files are collected through
    the framework_import_aspect aspect.

    Args:
        targets: The list of targets through which to collect the framework import files.
        targets_to_avoid: The list of targets that may already be bundling some of the frameworks,
            to be used when deduplicating frameworks already bundled.
        extra_binaries: Extra binaries to consider when collecting which archs should be
            preserved in the imported dynamic frameworks.

    Returns:
        A partial that returns the bundle location of the framework import files.
    """
    return partial.make(
        _framework_import_partial_impl,
        targets = targets,
        targets_to_avoid = targets_to_avoid,
        extra_binaries = extra_binaries,
    )

#
# Copyright (c) 2017-2021, salesforce.com, inc.
# All rights reserved.
# Licensed under the BSD 3-Clause license.
# For full license text, see LICENSE.txt file in the repo root  or https://opensource.org/licenses/BSD-3-Clause
#

#
# Spring Boot Packager
#
# See the macro documentation below for details.

# Spring Boot Executable JAR Layout specification
#   reverse engineered from the Spring Boot maven plugin

# /
# /META-INF/
# /META-INF/MANIFEST.MF                        <-- very specific manifest for Spring Boot (generated by this rule)
# /BOOT-INF
# /BOOT-INF/classes
# /BOOT-INF/classes/**/*.class                 <-- compiled application classes, must include @SpringBootApplication class
# /BOOT-INF/classes/META-INF/*                 <-- application level META-INF config files (e.g. spring.factories)
# /BOOT-INF/lib
# /BOOT-INF/lib/*.jar                          <-- all upstream transitive dependency jars must be here (except spring-boot-loader)
# /org/springframework/boot/loader
# /org/springframework/boot/loader/**/*.class  <-- the Spring Boot Loader classes must be here

# ***************************************************************
# Dependency Aggregator Rule
#  do not use directly, see the SpringBoot Macro below

def _depaggregator_rule_impl(ctx):
    merged = java_common.merge([dep[java_common.provider] for dep in ctx.attr.deps])
    return [DefaultInfo(files = depset(merged.transitive_runtime_jars.to_list()))]

_depaggregator_rule = rule(
    implementation = _depaggregator_rule_impl,
    attrs = {
        "depaggregator_rule": attr.label(),
        "deps": attr.label_list(providers = [java_common.provider]),
    },
)

def _appjar_locator_impl(ctx):
    if java_common.provider in ctx.attr.app_dep:
        output_jars = ctx.attr.app_dep[java_common.provider].runtime_output_jars
        if len(output_jars) != 1:
            fail("springboot rule expected 1 app jar but found %s" % len(output_jars))
    else:
        fail("Unable to locate the app jar")
    return [DefaultInfo(files = depset([output_jars[0]]))]

_appjar_locator_rule = rule(
    implementation = _appjar_locator_impl,
    attrs = {
        "app_dep": attr.label(),
    },
)

# ***************************************************************
# Package spring boot jar

def _genjar_rule_impl(ctx):
    # setup the output file
    output = ctx.actions.declare_file(ctx.attr.out)
    outputs = [output]

    inputs = []
    inputs += ctx.attr.app_jar.files.to_list()
    inputs += ctx.files.deps

    input_args = ctx.actions.args()
    input_args.add(ctx.attr.app_jar.files.to_list()[0])
    input_args.add(ctx.attr.boot_launcher_class)
    input_args.add(ctx.attr.boot_app_class)
    input_args.add(output.path)
    input_args.add_all(ctx.files.deps)
    # add the output file to the args, so python script knows where to write result

    # run the dupe checker
    ctx.actions.run(
        executable = ctx.executable.script,
        outputs = outputs,
        inputs = inputs,
        arguments = [input_args],
        progress_message = "Building spring boot jar...",
        mnemonic = "BootJarGen",
    )
    return [DefaultInfo(files = depset(outputs))]

_genjar_rule = rule(
    implementation = _genjar_rule_impl,
    attrs = {
        "genjar_rule": attr.label(),
        "script": attr.label(
            executable = True,
            cfg = "exec",
            allow_files = True,
        ),
        "boot_app_class": attr.string(),
        "boot_launcher_class": attr.string(),
        "app_jar": attr.label(),
        "deps":  attr.label_list(),
        "out": attr.string(),
    },
)


# ***************************************************************
# SpringBoot Rule
#  do not use directly, see the SpringBoot Macro below

def _springbootjar_rule_impl(ctx):
    outs = depset(transitive = [
        ctx.attr.app_compile_rule.files,
        ctx.attr.genjar_rule.files,
    ])

    return [DefaultInfo(
        files = outs,
    )]

_springbootjar_rule = rule(
    implementation = _springbootjar_rule_impl,
    attrs = {
        "app_compile_rule": attr.label(),
        "dep_aggregator_rule": attr.label(),
        "genjar_rule": attr.label(),
    },
)

# ***************************************************************
# SpringBootJar Macro
#  this is the entrypoint into the springbootjar rule
def springbootjar(
        name,
        java_library,
        boot_app_class,
        boot_launcher_class = "org.springframework.boot.loader.JarLauncher",
        deps = None,
        tags = [],
        testonly = False,
        visibility = None,
        ):
    """Bazel rule for packaging an executable Spring Boot application.

    Note that the rule README has more detailed usage instructions for each attribute.

    Args:
      name: **Required**. The name of the Spring Boot application. Typically this is set the same as the package name.
        Ex: *helloworld*.
      java_library: **Required**. The built jar, identified by the name of the java_library rule, that contains the
        Spring Boot application.
      boot_app_class: **Required**. The fully qualified name of the class annotated with @SpringBootApplication.
        Ex: *com.sample.SampleMain*
      deps: Optional. An additional set of Java dependencies to add to the executable.
        Normally all dependencies are set on the *java_library*.
    """
    # Create the subrule names
    dep_aggregator_rule = native.package_name() + "_deps"
    appjar_locator_rule = native.package_name() + "_appjar_locator"
    genjar_rule = native.package_name() + "_genjar"

    _appjar_locator_rule(
        name = appjar_locator_rule,
        app_dep = java_library,
        tags = tags,
        testonly = testonly,
    )

    # assemble deps; generally all deps will come transitively through the java_library
    # but a user may choose to add in more deps directly into the springboot jar (rare)
    java_deps = [java_library]
    if deps != None:
        java_deps = [java_library] + deps

    #  Aggregate transitive closure of upstream Java deps
    _depaggregator_rule(
        name = dep_aggregator_rule,
        deps = java_deps,
        testonly = testonly,
    )

    # generate spring boot jar 
    _genjar_rule(
            name = genjar_rule,
            script = "@rules_spring//springboot:springboot_pkg",
            deps = [ ":" + dep_aggregator_rule, ":" + appjar_locator_rule],
            boot_app_class = boot_app_class,
            boot_launcher_class = boot_launcher_class,
            app_jar = appjar_locator_rule,
            out = name + ".jar",
            tags = tags,
            testonly = testonly,
        )

    # MASTER RULE: Create the composite rule that will aggregate the outputs of the subrules
    _springbootjar_rule(
        name = name,
        app_compile_rule = java_library,
        dep_aggregator_rule = ":" + dep_aggregator_rule,
        genjar_rule = ":" + genjar_rule,

        tags = tags,
        testonly = testonly,
        visibility = visibility,
    )

# end springboot macro

"""Copyright (c) 2017, Anthony Scopatz"""
import networkx as nx

import os
import re
import sys

from xonsh.tools import print_color
import github3

from rever.tools import eval_version, indir, hash_url, replace_in_file
import copy
from pkg_resources import parse_version


def parsed_meta_yaml(text):
    """
    :param str text: The raw text in conda-forge feedstock meta.yaml file
    :return: `dict|None` -- parsed YAML dict if successful, None if not
    """
    try:
        yaml_dict = yaml.load(Template(text).render())

        # Pull the jinja2 variables out
        t = Template(text)
        variables = {}
        for e in t.env.parse(text).body:
            if isinstance(e, Assign):
                variables[e.target.name] = e.node.value

    except UndefinedError:
        # assume we hit a RECIPE_DIR reference in the vars and can't parse it.
        # just erase for now
        try:
            yaml_dict = yaml.load(
                Template(
                    re.sub('{{ (environ\[")?RECIPE_DIR("])? }}/', '',
                           text)
                ).render())
        except:
            return None
    except:
        return None

    return yaml_dict, yaml.load(text), variables


def feedstock_url(feedstock, protocol='ssh'):
    """Returns the URL for a conda-forge feedstock."""
    if feedstock is None:
        feedstock = $PROJECT + '-feedstock'
    elif feedstock.startswith('http://github.com/'):
        return feedstock
    elif feedstock.startswith('https://github.com/'):
        return feedstock
    elif feedstock.startswith('git@github.com:'):
        return feedstock
    protocol = protocol.lower()
    if protocol == 'http':
        url = 'http://github.com/conda-forge/' + feedstock + '.git'
    elif protocol == 'https':
        url = 'https://github.com/conda-forge/' + feedstock + '.git'
    elif protocol == 'ssh':
        url = 'git@github.com:conda-forge/' + feedstock + '.git'
    else:
        msg = 'Unrecognized github protocol {0!r}, must be ssh, http, or https.'
        raise ValueError(msg.format(protocol))
    return url


def feedstock_repo(feedstock):
    """Gets the name of the feedstock repository."""
    if feedstock is None:
        repo = $PROJECT + '-feedstock'
    else:
        repo = feedstock
    repo = repo.rsplit('/', 1)[-1]
    if repo.endswith('.git'):
        repo = repo[:-4]
    return repo


def fork_url(feedstock_url, username):
    """Creates the URL of the user's fork."""
    beg, end = feedstock_url.rsplit('/', 1)
    beg = beg[:-11]  # chop off 'conda-forge'
    url = beg + username + '/' + end
    return url


DEFAULT_PATTERNS = (
    # filename, pattern, new
    # set the version
    ('meta.yaml', '  version:\s*[A-Za-z0-9._-]+', '  version: "$VERSION"'),
    ('meta.yaml', '{% set version = ".*" %}', '{% set version = "$VERSION" %}'),
    # reset the build number to 0
    ('meta.yaml', '  number:.*', '  number: 0'),
    # set the hash
    ('meta.yaml', '{% set $HASH_TYPE = "[0-9A-Fa-f]+" %}',
                  '{% set $HASH_TYPE = "$HASH" %}'),
    ('meta.yaml', '  $HASH_TYPE:\s*[0-9A-Fa-f]+', '  $HASH_TYPE: $HASH'),
    )


def run(feedstock=None, protocol='ssh',
        hash_type='sha256', patterns=DEFAULT_PATTERNS,
        pull_request=True, rerender=True, fork=True, pred=[]):
    # first, let's grab the feedstock locally
    gh = github3.login($USERNAME, $PASSWORD)
    upstream = feedstock_url(feedstock, protocol=protocol)
    origin = fork_url(upstream, $USERNAME)
    feedstock_reponame = feedstock_repo(feedstock)

    if pull_request or fork:
        repo = gh.repository('conda-forge', feedstock_reponame)

    # Check if fork exists
    if fork:
        fork_repo = gh.repository($USERNAME, feedstock_reponame)
        if fork_repo is None or (hasattr(fork_repo, 'is_null') and
                                 fork_repo.is_null()):
            print("Fork doesn't exist creating feedstock fork...",
                  file=sys.stderr)
            repo.create_fork($USERNAME)

    feedstock_dir = os.path.join($REVER_DIR, $PROJECT + '-feedstock')
    recipe_dir = os.path.join(feedstock_dir, 'recipe')
    if not os.path.isdir(feedstock_dir):
        p = ![git clone @(origin) @(feedstock_dir)]
        if p.rtn != 0:
            msg = 'Could not clone ' + origin
            msg += '. Do you have a personal fork of the feedstock?'
            raise RuntimeError(msg)
    with indir(feedstock_dir):
        # make sure feedstock is up-to-date with origin
        git checkout master
        git pull @(origin) master
        # make sure feedstock is up-to-date with upstream
        git pull @(upstream) master
        # make and modify version branch
        with ${...}.swap(RAISE_SUBPROC_ERROR=False):
            git checkout -b $VERSION master or git checkout $VERSION
    # Render with new version but nothing else
    with indir(recipe_dir):
        for f, p, n in patterns:
            p = eval_version(p)
            n = eval_version(n)
            replace_in_file(p, n, f)
        with open('meta.yaml', 'r') as f:
            text = f.read()
        meta_yaml = parsed_meta_yaml(text)
        source_url = meta_yaml['source']['url']

    # now, update the feedstock to the new version
    source_url = eval_version(source_url)
    hash = hash_url(source_url)
    with indir(recipe_dir), ${...}.swap(HASH_TYPE=hash_type, HASH=hash,
                                        SOURCE_URL=source_url):
        for f, p, n in patterns:
            p = eval_version(p)
            n = eval_version(n)
            replace_in_file(p, n, f)
    with indir(feedstock_dir), ${...}.swap(RAISE_SUBPROC_ERROR=False):
        git commit -am @("updated v" + $VERSION)
        if rerender:
            print_color('{YELLOW}Rerendering the feedstock{NO_COLOR}',
                        file=sys.stderr)
            conda smithy rerender -c auto
        git push --set-upstream @(origin) $VERSION
    # lastly make a PR for the feedstock
    if not pull_request:
        return
    print('Creating conda-forge feedstock pull request...', file=sys.stderr)
    title = $PROJECT + ' v' + $VERSION
    head = $USERNAME + ':' + $VERSION
    body = ('Merge only after success.\n\n'
            'This pull request was auto-generated by '
            '[rever](https://regro.github.io/rever-docs/)\n'
            'Here is a list of all the pending dependencies (and their '
            'versions) for this repo.'
            'Please double check all dependencies before merging.\n\n')
    # Statement here
    template = '{name}: {new_version}, [![Anaconda-Server Badge](https://anaconda.org/conda-forge/{name}/badges/version.svg)](https://anaconda.org/conda-forge/{name})\n'
    body += '''
    | Name | Upstream Version | Current Version |
    |:----:|:----------------:|:---------------:|
    '''
    for p in pred:
        body += template.replace(name=$PROJECT, new_version=$VERSION)
    pr = repo.create_pull(title, 'master', head, body=body)
    if pr is None:
        print_color('{RED}Failed to create pull request!{NO_COLOR}')
    else:
        print_color('{GREEN}Pull request created at ' + pr.html_url + \
                    '{NO_COLOR}')


gx = nx.read_gpickle('graph2.pkl')
gx2 = copy.deepcopy(gx)

# Prune graph to only things that need builds
for node, attrs in gx2.node.items():
    if parse_version(attrs['new_version']) <= parse_version(attrs['version']):
        gx2.remove_node(node)

$REVER_DIR = '.'
for node, attrs in gx.node.items():
    # If not already PR'ed and if no deps
    if not attrs.get('PRed', False):
        pred =  list(gx2.predecessors(node))
        $VERSION = attrs['new_version']
        $PROJECT = attrs['name']
        run(pred=pred)
        gx.nodes[node]['PRed'] = True

# Race condition?
nx.write_gpickle(gx, 'graph2.pkl')

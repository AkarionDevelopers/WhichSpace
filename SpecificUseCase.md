This is a fork of a general Window Spacing tool for mac that optimizes it for our specific use case:

We have 3 git instances of the same monorepo downloaded into 3 different folders, so we can have agents doing tasks in each of them. The setup is to have VSCode open in each Space with a different folder. Claude Code is installed as extension. With whichspace we can colorize each space and quickly jump between those tasks and quickly knowing where we are at. This is very helpful for juggling a lot of different tasks, because you need to adjust your brain to know the right context again, so coloring and labeling helps a lot.

While whichspace it great in helping in this use-case it still lacks a few features:

1. In a multi-monitor setup the label is confusing, because each monitor has the same connected naming. In our setup only one of the monitors is the main work horse where the vscode instances live, the other ones are for browsers, slack, notes, etc and don't actually need a naming
2. It can not visualize when a session is finished or input is needed. it would be great if it could communictate with the claude code instance somehow and know when it is finished
3. Applying labels to each Desktop is currently cumbersome, because it is nested in sublayers. This should be easier, because tasks change all the time. Ideally it would even just show the current branch of the first vscode instance it finds as label
